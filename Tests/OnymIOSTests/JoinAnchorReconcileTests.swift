import XCTest
@testable import OnymIOS
import OnymChain
import OnymIdentity
@testable import OnymGroup

/// What the approver does when the contract answers
/// `PublicInputsMismatch` (`Error(Contract, #10)`) — the refusal that
/// means "you proved a step out of a state I am not in".
///
/// The case that produces it in the field: an `update_commitment` whose
/// transaction reached the ledger and whose *answer* did not reach the
/// phone. The founder sees the first Accept fail, taps again, and the
/// second tap proves from an epoch the chain has already left.
///
/// The salt those transactions moved to is random — it has to be, it is
/// what stops a chain observer confirming a guessed roster — so the
/// only thing that can identify the one that landed is the record
/// written before it was submitted. These pin that identification, the
/// epoch rebase that needs no record, and, just as deliberately, the
/// cases where nothing can be recovered and the approver has to say so
/// instead of re-proving into the same wall.
///
/// Poseidon runs for real here: the commitments are the SDK's, not a
/// stand-in, so a match means what the contract would mean by it. (Its
/// Android twin injects the recompute — the JNI is androidTest-only
/// there.)
final class JoinAnchorReconcileTests: XCTestCase {

    private let owner = IdentityID()
    private let admin = GovernanceMember(
        publicKeyCompressed: Data(repeating: 0x0A, count: 48),
        leafHash: Data(repeating: 0x0B, count: 32)
    )
    private let joiner = GovernanceMember(
        publicKeyCompressed: Data(repeating: 0x1A, count: 48),
        leafHash: Data(repeating: 0x1B, count: 32)
    )
    /// The salt the lost transaction drew. Random in production; fixed
    /// here so the test can play both the chain and the record.
    private let lostSalt = Data(repeating: 0x5C, count: 32)

    private func group(
        epoch: UInt64 = 3,
        salt: Data = Data(repeating: 0x66, count: 32),
        members: [GovernanceMember]? = nil
    ) throws -> ChatGroup {
        let roster = members ?? [admin]
        return ChatGroup(
            id: Data(repeating: 0xAB, count: 32).hexString,
            ownerIdentityID: owner,
            name: "Montelibero",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            members: roster,
            memberProfiles: [:],
            epoch: epoch,
            salt: salt,
            commitment: try commitment(roster, epoch: epoch, salt: salt),
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: admin.publicKeyCompressed.hexString,
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: true
        )
    }

    private func commitment(
        _ members: [GovernanceMember],
        epoch: UInt64,
        salt: Data
    ) throws -> Data {
        try GroupCommitmentBuilder.computePoseidonCommitment(
            poseidonRoot: try GroupCommitmentBuilder.computeMerkleRoot(
                members: members,
                tier: .small
            ),
            epoch: epoch,
            salt: salt
        )
    }

    /// What the chain holds after the lost transaction landed.
    private func landedEntry(
        _ g: ChatGroup,
        member: GovernanceMember? = nil,
        salt: Data? = nil
    ) throws -> SEPCommitmentEntry {
        let joined = member ?? joiner
        return SEPCommitmentEntry(
            commitment: try commitment(
                g.members + [joined],
                epoch: g.epoch + 1,
                salt: salt ?? lostSalt
            ),
            epoch: g.epoch + 1
        )
    }

    /// The row `JoinRequestApprover` writes before it submits.
    private func record(
        _ g: ChatGroup,
        member: GovernanceMember? = nil,
        salt: Data? = nil,
        epochOld: UInt64? = nil,
        at seconds: TimeInterval = 0
    ) -> PendingAnchor {
        let joined = member ?? joiner
        return PendingAnchor(
            groupID: g.groupIDData,
            ownerIdentityID: g.ownerIdentityID,
            epochOld: epochOld ?? g.epoch,
            joinerPublicKey: joined.publicKeyCompressed,
            joinerLeafHash: joined.leafHash,
            saltNew: salt ?? lostSalt,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds)
        )
    }

    // MARK: - adopt: the earlier attempt actually landed

    /// The heart of it. The chain is at exactly the state one recorded
    /// attempt would have produced, so that attempt is the one that
    /// landed — and there is nothing left to submit. The device adopts
    /// it, salt included, and the approval carries on to the invitation
    /// the joiner never received.
    func test_adoptsTheChainState_whenARecordedAttemptLanded() throws {
        let g = try group()
        let entry = try landedEntry(g)

        let adopted = adoptLandedAnchor(group: g, entry: entry, candidates: [record(g)])

        let unwrapped = try XCTUnwrap(adopted)
        XCTAssertEqual(unwrapped.group.epoch, 4)
        XCTAssertEqual(unwrapped.group.members.count, 2)
        XCTAssertEqual(unwrapped.joinerPublicKey, joiner.publicKeyCompressed)
        // The salt is the point: without it back in hand the next
        // member-add could never prove from this state.
        XCTAssertEqual(unwrapped.group.salt, lostSalt)
        XCTAssertEqual(unwrapped.group.commitment, entry.commitment)
    }

    /// Two approvals from the same epoch, one of them landed. The
    /// founder is trying to approve the *other* one, and the reconcile
    /// has to name whichever transaction actually made it — the
    /// approver then re-proves the join it was asked for from there.
    func test_namesWhicheverAttemptLanded_evenIfItIsNotThisJoiner() throws {
        let other = GovernanceMember(
            publicKeyCompressed: Data(repeating: 0x2A, count: 48),
            leafHash: Data(repeating: 0x2B, count: 32)
        )
        let otherSalt = Data(repeating: 0x3C, count: 32)
        let g = try group()
        let entry = try landedEntry(g, member: other, salt: otherSalt)

        let adopted = adoptLandedAnchor(
            group: g,
            entry: entry,
            // Newest first, as the store returns them: this joiner's
            // attempt is the more recent one and is *not* the one that
            // landed.
            candidates: [
                record(g, at: 60),
                record(g, member: other, salt: otherSalt, at: 0)
            ]
        )

        let unwrapped = try XCTUnwrap(adopted)
        XCTAssertEqual(unwrapped.joinerPublicKey, other.publicKeyCompressed)
        XCTAssertEqual(unwrapped.group.salt, otherSalt)
        XCTAssertTrue(
            unwrapped.group.members.contains { $0.publicKeyCompressed == other.publicKeyCompressed },
            "the landed joiner is in the adopted roster"
        )
        XCTAssertFalse(
            unwrapped.group.members.contains { $0.publicKeyCompressed == joiner.publicKeyCompressed },
            "the joiner still being approved is not"
        )
    }

    /// The roster it adopts is the canonical lex ordering, not
    /// append-order — the same ordering the proof and the contract agree
    /// on, or the next update commits to a different tree.
    func test_theAdoptedRosterIsLexSorted() throws {
        let early = GovernanceMember(
            publicKeyCompressed: Data(repeating: 0x01, count: 48),
            leafHash: Data(repeating: 0x02, count: 32)
        )
        let g = try group(members: [admin, early])
        let entry = try landedEntry(g)

        let adopted = try XCTUnwrap(
            adoptLandedAnchor(group: g, entry: entry, candidates: [record(g)])
        )

        XCTAssertEqual(adopted.group.members[0].publicKeyCompressed, early.publicKeyCompressed)
        XCTAssertEqual(adopted.group.members[2].publicKeyCompressed, joiner.publicKeyCompressed)
    }

    /// No record, nothing to recompute against — the shape every group
    /// anchored by a build that kept none is in. The chain is one epoch
    /// ahead and the device cannot say why, which is exactly what it has
    /// to report rather than guess at.
    func test_cannotAdopt_withoutARecordOfTheAttempt() throws {
        let g = try group()
        XCTAssertNil(
            adoptLandedAnchor(group: g, entry: try landedEntry(g), candidates: [])
        )
    }

    /// A record whose salt isn't the one the chain committed to is not
    /// the transaction that landed, however close the epoch looks.
    func test_refusesToAdopt_aRecordWhoseCommitmentDoesNotMatch() throws {
        let g = try group()
        XCTAssertNil(
            adoptLandedAnchor(
                group: g,
                entry: try landedEntry(g),
                candidates: [record(g, salt: Data(repeating: 0x7E, count: 32))]
            )
        )
    }

    /// Two epochs ahead is not "our attempt landed" — an accepted proof
    /// advances the chain by exactly one, so something else moved it.
    func test_refusesToAdopt_whenTheChainIsFurtherAheadThanOneStep() throws {
        let g = try group()
        let landed = try landedEntry(g)
        let further = SEPCommitmentEntry(
            commitment: landed.commitment,
            epoch: landed.epoch + 1
        )
        XCTAssertNil(
            adoptLandedAnchor(group: g, entry: further, candidates: [record(g)])
        )
    }

    /// A record left over from an epoch the group has already left
    /// cannot describe the step the chain just took.
    func test_ignoresRecords_fromAnEpochTheGroupHasLeft() throws {
        let g = try group(epoch: 3)
        XCTAssertNil(
            adoptLandedAnchor(
                group: g,
                entry: try landedEntry(g),
                candidates: [record(g, epochOld: 2)]
            )
        )
    }

    /// A record for someone already in the roster was resolved and
    /// merely outlived its sweep. Re-adding the leaf would build a tree
    /// the contract never committed to.
    func test_ignoresRecords_forMembersAlreadyInTheRoster() throws {
        let g = try group(members: [admin, joiner])
        XCTAssertNil(
            adoptLandedAnchor(
                group: g,
                entry: try landedEntry(g),
                candidates: [record(g)]
            )
        )
    }

    // MARK: - rebase: only the counter drifted

    /// Same roster, same salt, later epoch: re-prove from the chain's
    /// number rather than the device's.
    func test_rebasesOntoTheChainEpoch_whenOnlyTheCounterDrifted() throws {
        let g = try group(epoch: 3)
        let entry = SEPCommitmentEntry(
            commitment: try commitment(g.members, epoch: 5, salt: g.salt),
            epoch: 5
        )

        let rebased = try XCTUnwrap(rebaseOnChainEpoch(group: g, entry: entry))

        XCTAssertEqual(rebased.epoch, 5)
        XCTAssertEqual(rebased.commitment, entry.commitment)
        XCTAssertEqual(rebased.members.count, g.members.count)
        XCTAssertEqual(rebased.salt, g.salt)
    }

    /// Epochs already agree, so the mismatch was about something else —
    /// the roster, the salt, the group id. Re-proving would spend the
    /// founder's 3-5 seconds to be refused in exactly the same way.
    func test_doesNotRebase_whenTheEpochsAlreadyAgree() throws {
        let g = try group(epoch: 3)
        XCTAssertNil(
            rebaseOnChainEpoch(
                group: g,
                entry: SEPCommitmentEntry(commitment: try XCTUnwrap(g.commitment), epoch: 3)
            )
        )
    }

    /// A later epoch over a roster this device can't reproduce is a real
    /// divergence, not a drifted counter.
    func test_doesNotRebase_ontoACommitmentItCannotReproduce() throws {
        let g = try group(epoch: 3)
        XCTAssertNil(
            rebaseOnChainEpoch(
                group: g,
                entry: SEPCommitmentEntry(
                    commitment: Data(repeating: 0x5C, count: 32),
                    epoch: 5
                )
            )
        )
    }
}
