import Foundation
import OnymGroup
import OnymStellar

/// Decides whether an arriving proposal is one this device will put in
/// front of a co-signer, and what it is asking for.
///
/// This is the boundary the whole feature's safety rests on. A member
/// of the group can send any bytes they like; everything past this
/// point is rendered as a thing worth signing. So the rules here are
/// deliberately closed — a proposal must be affirmatively recognisable,
/// and anything unrecognised is refused rather than shown with the
/// unfamiliar parts omitted.
///
/// Displaying a proposal with an operation the app could not decode
/// would be the worst possible outcome: the co-signer sees three
/// innocuous rows, signs, and the fourth operation is the one that
/// mattered. That is why `StellarOperation.decode` has no default arm
/// and why `unsupportedOperation` exists.
public enum TreasuryProposalVerifier {

    /// The most a proposal may offer per operation, in stroops.
    ///
    /// A hundred times the protocol's base fee of 100 stroops — high
    /// enough to clear any realistic surge, low enough that the worst
    /// case is 0.001 XLM an operation rather than an unbounded transfer
    /// to the validators. Deliberately a ceiling rather than an exact
    /// match: a proposal built during a busy ledger legitimately pays
    /// more than one built on a quiet one.
    public static let maxFeePerOperation: UInt32 = 10_000

    /// The longest a proposal may stay live, in seconds.
    ///
    /// Matches `TreasuryProposalInteractor.proposalWindow`, with a
    /// day's slack for clock skew between the proposer and whoever is
    /// checking. A peer is not this app and can put anything it likes
    /// in `timeBounds`.
    public static let maxLifetime: TimeInterval = 8 * 24 * 3600

    /// The most signatures an *inbound* proposal may already carry.
    ///
    /// Zero would be tidier but the proposer legitimately signs their
    /// own proposal before sending it, and a relay may deliver a
    /// proposal that already gathered a few. The cap is what matters:
    /// `TransactionEnvelope` refuses to append past twenty, so a
    /// proposal arriving full can never be signed by anybody.
    public static let maxInboundSignatures = 4

    /// How far past the account's current sequence a proposal may
    /// claim.
    ///
    /// Bounding `maxTime` closed one door to a frozen treasury and left
    /// the other open: a proposal at `sequence + 10^9` is accepted, and
    /// the one-open-proposal rule then answers `.sequenceContended` for
    /// every new proposal on every honest device until it expires —
    /// repeatable, for the cost of one message. A real proposal claims
    /// the *next* sequence; a small window tolerates the race where two
    /// devices read the account moments apart.
    public static let maxSequenceLookahead: Int64 = 8


    /// What the verifier concluded.
    public enum Outcome: Equatable, Sendable {
        case accepted(TreasuryProposalKind)
        case rejected(TreasuryRejection)
    }

    /// Check a decoded envelope against the group's anchored treasury.
    ///
    /// - Parameters:
    ///   - envelope: decoded on this device from the proposal's XDR.
    ///   - treasury: what this device has anchored for the group. Nil
    ///     when the group has no treasury, which is itself a refusal —
    ///     a proposal for a treasury we do not know about is not
    ///     something to display.
    ///   - proposerBlsPubkeyHex: taken from the verified envelope
    ///     sender, not from the payload body.
    ///   - group: the roster the proposer must appear in.
    public static func verify(
        envelope: TransactionEnvelope,
        network: StellarNetwork,
        treasury: Treasury?,
        proposerBlsPubkeyHex: String,
        group: ChatGroup,
        /// The treasury's sequence as the chain last reported it. Nil
        /// when this device has not managed a live read.
        currentSequence: Int64? = nil,
        now: Date = Date()
    ) -> Outcome {
        guard let treasury else { return .rejected(.noTreasury) }

        // The proposer must be someone this group knows. A stranger who
        // learned the group's inbox keys could otherwise put a payment
        // card in the thread.
        let proposer = proposerBlsPubkeyHex.lowercased()
        guard group.memberProfiles[proposer] != nil else {
            return .rejected(.proposerNotAMember)
        }

        // The network is inside the transaction hash, so a mismatch
        // means every signature collected here would verify against
        // nothing. Checked explicitly so it fails as a clear refusal
        // rather than as signatures that mysteriously never add up.
        guard network == treasury.network else {
            return .rejected(.wrongNetwork)
        }

        // The transaction must spend *this* treasury.
        guard envelope.transaction.sourceAccount == treasury.account else {
            return .rejected(.notThisTreasury)
        }

        // Every operation must act on the treasury or inherit its
        // source. An operation naming a third account would have this
        // group's quorum authorise something on an account it does not
        // own — and the signature is just as valid for that.
        for operation in envelope.transaction.operations {
            if let source = operation.sourceAccount, source != treasury.account {
                return .rejected(.foreignOperationSource)
            }
        }

        // Time bounds are attacker-controlled, and their absence is
        // what makes a proposal immortal.
        //
        // The decoder accepts PRECOND_NONE, `expiresAt` is nil for it,
        // and the one-open-proposal rule reads nil as "still live". So
        // one well-formed payment proposal with no time bounds claims
        // the treasury's next sequence number forever: every honest
        // device then answers `.sequenceContended` for every new
        // proposal, nothing expires it, and there is no dismiss path.
        // Any member could freeze the treasury permanently, for the
        // cost of one message.
        //
        // `TreasuryProposal`'s own doc says this app always builds
        // bounded transactions — but a peer is not this app, and that
        // is exactly the assumption this boundary exists to stop
        // trusting.
        guard let bounds = envelope.transaction.timeBounds, bounds.maxTime != 0 else {
            return .rejected(.noExpiry)
        }
        let latestPermitted = now.addingTimeInterval(maxLifetime).timeIntervalSince1970
        guard TimeInterval(bounds.maxTime) <= latestPermitted else {
            return .rejected(.expiresTooLate)
        }

        // The sequence number is attacker-controlled too, and unbounded
        // it freezes the treasury exactly as a missing time bound does
        // — through the other field. Checked only when a live account
        // read is available; without one the caller cannot know the
        // current sequence, and refusing on that basis would drop
        // genuine proposals whenever the network is unreachable.
        if let currentSequence {
            let claimed = envelope.transaction.sequenceNumber
            guard claimed > currentSequence,
                  claimed <= currentSequence + maxSequenceLookahead
            else {
                return .rejected(.implausibleSequence)
            }
        }

        // An envelope arriving with twenty junk signatures verifies
        // cleanly and can then never be signed by anyone: `append`
        // refuses past the protocol's cap, which surfaces to a
        // co-signer as "signature did not verify". Cheap griefing on
        // its own, and a sequence lock when combined with the above.
        guard envelope.signatures.count <= maxInboundSignatures else {
            return .rejected(.tooManySignatures)
        }

        // The fee is a real spend that appears in no operation row, and
        // the card is built from operations only. `fee = UInt32.max` on
        // a one-stroop payment is ~429 XLM leaving the treasury with
        // nothing on screen to show for it. Bounded here, and also
        // shown by `TreasuryProposalDescription` when it is above the
        // ordinary rate, so the two defences are independent.
        let operationCount = UInt32(envelope.transaction.operations.count)
        guard envelope.transaction.fee <= maxFeePerOperation * max(operationCount, 1) else {
            return .rejected(.excessiveFee)
        }

        guard let kind = kind(of: envelope.transaction.operations) else {
            return .rejected(.unsupportedOperation)
        }
        return .accepted(kind)
    }

    /// Classify the operations into the one thing the proposal is for.
    ///
    /// A mixed proposal — a payment *and* a signer change in one
    /// envelope — returns nil and is refused. Not because Stellar
    /// forbids it, but because a single card cannot honestly summarise
    /// two different asks at two different thresholds, and the
    /// summary is what people read before signing.
    ///
    /// The one deliberate exception is a run of `setOptions`, which is
    /// how a control change is expressed: adding a signer and raising
    /// the threshold to match has to be atomic, or the account spends
    /// the gap between them in a state nobody chose.
    public static func kind(of operations: [StellarOperation]) -> TreasuryProposalKind? {
        guard !operations.isEmpty else { return nil }

        if operations.count == 1 {
            switch operations[0].body {
            case .payment:
                return .payment
            case .changeTrust:
                return .trustline
            case .setOptions(let fields):
                // Adding a signer with weight > 0 is a nomination.
                // Anything else that touches thresholds or removes a
                // signer is a change of control. Both are high
                // threshold, so the distinction is only about wording.
                if let signer = fields.signer, signer.weight > 0, !touchesThresholds(fields) {
                    return .addSigner
                }
                return .changeControl
            case .createAccount:
                // Creation is signed by the founder and the new account
                // itself, never proposed to a group: the treasury does
                // not exist yet, so there is no signer set to ask.
                return nil
            }
        }

        let allSetOptions = operations.allSatisfy {
            if case .setOptions = $0.body { return true }
            return false
        }
        return allSetOptions ? .changeControl : nil
    }

    private static func touchesThresholds(_ fields: SetOptionsFields) -> Bool {
        fields.masterWeight != nil
            || fields.lowThreshold != nil
            || fields.mediumThreshold != nil
            || fields.highThreshold != nil
    }

    /// Where a proposal stands right now, given a fresh account read.
    ///
    /// `account` must be a live read. Passing a cached snapshot would
    /// make `.ready` a claim about a signer set that may have changed,
    /// and `.ready` is the answer that causes a submission.
    public static func standing(
        of proposal: TreasuryProposal,
        account: HorizonAccount,
        declaredSigners: [StellarAccountID],
        now: Date
    ) -> TreasuryProposalStanding {
        if let hash = proposal.submittedTxHash {
            return .submitted(txHash: hash)
        }
        // Checked before expiry: a transaction whose sequence has been
        // consumed is dead regardless of its time bounds, and
        // "superseded" is the more useful thing to tell someone —
        // it says another transaction won, not that they were slow.
        if account.sequenceNumber >= proposal.sequenceNumber {
            return .superseded
        }
        if let expiresAt = proposal.expiresAt, expiresAt <= now {
            return .expired
        }
        let signed = proposal.signers(among: declaredSigners)
        let weight = account.weight(of: signed)
        let required = proposal.kind.requiredWeight(from: account.thresholds)
        return weight >= required
            ? .ready
            : .collecting(weight: weight, required: required)
    }
}
