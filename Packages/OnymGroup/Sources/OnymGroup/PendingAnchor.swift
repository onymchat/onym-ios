import Foundation
import OnymChain
import OnymIdentity

/// One `update_commitment` this device is about to submit, written down
/// before it goes out so the attempt survives losing its answer.
///
/// ## Why this exists
///
/// A member-add moves the group to a commitment over a *fresh random
/// salt*. The salt is random on purpose: it is the blinding factor that
/// stops anyone reading the chain from confirming a guessed roster by
/// recomputation, and deriving it from state other members hold would
/// hand that power to everyone who has ever been in the group.
///
/// The cost of randomness is that the value exists nowhere but the
/// memory of the process that drew it. If the transaction reaches the
/// ledger and the answer does not reach the phone — a relayer 502, a
/// dropped connection, a force-quit — the chain is now committed to a
/// salt this device cannot name. Every later member-add proves from a
/// state the contract no longer holds and is refused
/// `PublicInputsMismatch` (`Error(Contract, #10)`), forever: the
/// group's roster frozen with no way back.
///
/// So the salt is written to disk *before* the submit. Then a refusal
/// is answerable — `adoptLandedAnchor` recomputes the commitment each
/// recorded attempt would have produced and compares it to what the
/// chain actually holds, which identifies the transaction that landed
/// and hands back the state to adopt.
///
/// Records are kept per `(group, local identity)` and swept the moment
/// the group advances past them: once the chain leaves epoch N, no
/// proof from N can ever be accepted again, so nothing at or below N
/// can still be waiting to land.
public struct PendingAnchor: Equatable, Sendable {
    public let groupID: Data
    /// Which local identity's copy of the group this was proved from;
    /// two identities can hold rows for the same on-chain group.
    public let ownerIdentityID: IdentityID
    /// The epoch this attempt proved *from*. What makes a record
    /// answerable: it can only have landed if the chain now sits at
    /// exactly `epochOld + 1`.
    public let epochOld: UInt64
    public let joinerPublicKey: Data
    public let joinerLeafHash: Data
    /// The value the whole record exists to keep.
    public let saltNew: Data
    public let createdAt: Date

    public init(
        groupID: Data,
        ownerIdentityID: IdentityID,
        epochOld: UInt64,
        joinerPublicKey: Data,
        joinerLeafHash: Data,
        saltNew: Data,
        createdAt: Date
    ) {
        self.groupID = groupID
        self.ownerIdentityID = ownerIdentityID
        self.epochOld = epochOld
        self.joinerPublicKey = joinerPublicKey
        self.joinerLeafHash = joinerLeafHash
        self.saltNew = saltNew
        self.createdAt = createdAt
    }
}

/// Durable record of in-flight anchor attempts.
///
/// `record` has to reach disk before the transaction reaches the
/// relayer, or the force-quit window it exists to cover is exactly the
/// window it misses. It throws rather than reporting a `Bool` for the
/// same reason: a caller that cannot keep the salt must refuse to
/// submit, not carry on and hope.
public protocol PendingAnchorStore: Sendable {

    /// Write down an attempt about to be submitted.
    ///
    /// Attempts from epochs the group has already left are swept here
    /// too, so a group that fails repeatedly doesn't accumulate rows
    /// that can no longer explain anything.
    func record(_ anchor: PendingAnchor) async throws

    /// Every attempt recorded for this group that could still be
    /// waiting to land, newest first.
    func pending(groupID: Data, ownerIdentityID: IdentityID) async -> [PendingAnchor]

    /// Drop every attempt that proved from `throughEpoch` or earlier —
    /// the chain has moved past them and none can land now.
    func clear(groupID: Data, ownerIdentityID: IdentityID, throughEpoch: UInt64) async
}

/// Keeps nothing. The default for call sites that don't anchor
/// (non-Tyranny groups, tests that never reach the chain leg) —
/// recovery then degrades to what it was before this existed: a
/// refusal the founder can read, rather than a silent one.
public struct NoopPendingAnchorStore: PendingAnchorStore {
    public init() {}
    public func record(_ anchor: PendingAnchor) async throws {}
    public func pending(groupID: Data, ownerIdentityID: IdentityID) async -> [PendingAnchor] { [] }
    public func clear(groupID: Data, ownerIdentityID: IdentityID, throughEpoch: UInt64) async {}
}

/// Process-lifetime `PendingAnchorStore`.
///
/// The fallback when the on-disk store won't open, and what tests use
/// when they only need the recovery logic rather than its durability.
public actor InMemoryPendingAnchorStore: PendingAnchorStore {
    private var rows: [PendingAnchor] = []
    /// When set, `record` throws it — the case the approver treats as a
    /// refusal to submit.
    private var recordError: Error?

    public init() {}

    public func failRecords(with error: Error) { recordError = error }

    public func record(_ anchor: PendingAnchor) async throws {
        if let recordError { throw recordError }
        rows.removeAll {
            $0.groupID == anchor.groupID
                && $0.ownerIdentityID == anchor.ownerIdentityID
                && $0.epochOld < anchor.epochOld
        }
        rows.append(anchor)
    }

    public func pending(groupID: Data, ownerIdentityID: IdentityID) async -> [PendingAnchor] {
        rows
            .filter { $0.groupID == groupID && $0.ownerIdentityID == ownerIdentityID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func clear(groupID: Data, ownerIdentityID: IdentityID, throughEpoch: UInt64) async {
        rows.removeAll {
            $0.groupID == groupID
                && $0.ownerIdentityID == ownerIdentityID
                && $0.epochOld <= throughEpoch
        }
    }
}

/// A recorded attempt the chain turns out to have accepted, and the
/// state adopting it puts this device in.
public struct AdoptedAnchor: Equatable, Sendable {
    public let group: ChatGroup
    public let joinerPublicKey: Data
}

/// The recorded attempt that `entry` shows actually landed, if one did.
///
/// Each `PendingAnchor` kept the salt its transaction was moving to, so
/// the commitment it would have produced is recomputable: roster plus
/// that joiner, at `epochOld + 1`, under that salt. Exactly one can
/// match what the chain holds — a commitment is binding, so a match is
/// an identification, not a guess.
///
/// Checked by recomputing rather than by trusting the epoch counter. A
/// matching epoch over a different roster is a different group state,
/// and adopting it would put the founder's device into a belief the
/// chain does not share.
///
/// `nil` when the chain is somewhere none of the records explain —
/// including when there are no records, which is every group anchored
/// before they were kept.
///
/// Free functions rather than methods on the approver, and without the
/// commitment-recompute seam its Android twin carries: the Poseidon
/// calls are reachable from the test target here, so these are tested
/// against the real thing.
public func adoptLandedAnchor(
    group: ChatGroup,
    entry: SEPCommitmentEntry,
    candidates: [PendingAnchor]
) -> AdoptedAnchor? {
    // Only a single step forward can be one of ours: every recorded
    // attempt proved from an epoch, and an accepted proof advances the
    // chain by exactly one.
    guard entry.epoch == group.epoch + 1 else { return nil }

    for candidate in candidates {
        guard candidate.epochOld == group.epoch else { continue }
        // Already in the roster — this record was resolved and merely
        // outlived its sweep. Adding the leaf twice would build a tree
        // the contract never committed to.
        if group.members.contains(where: { $0.publicKeyCompressed == candidate.joinerPublicKey }) {
            continue
        }
        let newMembers = (
            group.members + [
                GovernanceMember(
                    publicKeyCompressed: candidate.joinerPublicKey,
                    leafHash: candidate.joinerLeafHash
                )
            ]
        ).sorted { lhs, rhs in
            lhs.publicKeyCompressed.lexicographicallyPrecedes(rhs.publicKeyCompressed)
        }
        guard
            let root = try? GroupCommitmentBuilder.computeMerkleRoot(
                members: newMembers,
                tier: group.tier
            ),
            let expected = try? GroupCommitmentBuilder.computePoseidonCommitment(
                poseidonRoot: root,
                epoch: entry.epoch,
                salt: candidate.saltNew
            ),
            expected == entry.commitment
        else { continue }

        var adopted = group
        adopted.members = newMembers
        adopted.commitment = entry.commitment
        adopted.epoch = entry.epoch
        adopted.salt = candidate.saltNew
        return AdoptedAnchor(group: adopted, joinerPublicKey: candidate.joinerPublicKey)
    }
    return nil
}

/// `group` moved onto the chain's epoch, if the chain holds this exact
/// roster and salt and only the counter drifted — the shape a
/// half-persisted or replayed update leaves behind.
///
/// `nil` when the epochs already agree (the mismatch was something
/// else, and re-proving would spend 3-5 seconds to be refused
/// identically) or when the chain's commitment isn't over state this
/// device can reproduce.
public func rebaseOnChainEpoch(
    group: ChatGroup,
    entry: SEPCommitmentEntry
) -> ChatGroup? {
    guard entry.epoch != group.epoch else { return nil }
    guard
        let root = try? GroupCommitmentBuilder.computeMerkleRoot(
            members: group.members,
            tier: group.tier
        ),
        let expected = try? GroupCommitmentBuilder.computePoseidonCommitment(
            poseidonRoot: root,
            epoch: entry.epoch,
            salt: group.salt
        ),
        expected == entry.commitment
    else { return nil }

    var rebased = group
    rebased.commitment = entry.commitment
    rebased.epoch = entry.epoch
    return rebased
}
