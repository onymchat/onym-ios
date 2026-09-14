import XCTest
@testable import OnymStellar
@testable import OnymTreasury

/// The arithmetic behind "what does it now take to spend?".
///
/// This is the one piece of real logic the redesign asks for: every
/// screen that sets a weight or a bar carries a live sentence naming
/// who can clear it, and a sentence that is wrong is worse than the
/// "1/1" it replaces.
final class TreasuryQuorumTests: XCTestCase {

    private func account(_ n: UInt8) -> StellarAccountID { TreasuryTestKeys.account(n) }

    private func quorum(
        weights: [UInt32],
        medium: UInt32,
        high: UInt32? = nil
    ) -> TreasuryQuorum {
        TreasuryQuorum(
            coSigners: weights.enumerated().map {
                TreasuryCoSigner(account: account(UInt8($0.offset + 40)), weight: $0.element)
            },
            thresholds: TreasuryThresholds(low: 1, medium: medium, high: high ?? medium)
        )
    }

    /// Weights are not headcount. Two people at 2 carry as far as four
    /// at 1, and every screen that counted signers instead of weight
    /// would set a bar the ledger reads differently.
    func test_totalWeight_countsWeightNotPeople() {
        XCTAssertEqual(quorum(weights: [2, 2], medium: 4).totalWeight, 4)
        XCTAssertEqual(quorum(weights: [1, 1, 1, 1], medium: 4).totalWeight, 4)
    }

    /// A bar above the total is an account no quorum can ever act on —
    /// including to repair the bar. Stellar accepts it; nobody can
    /// undo it.
    func test_aBarAboveTheTotalWeight_isNotReachable() {
        XCTAssertFalse(quorum(weights: [1, 1], medium: 3).isReachable)
        XCTAssertTrue(quorum(weights: [1, 1], medium: 2).isReachable)
    }

    /// `high` below `medium` means any single co-signer can reweight
    /// themselves to sole control and then spend alone.
    func test_aLowerBarForChangingControl_isNotReachable() {
        XCTAssertFalse(quorum(weights: [1, 1, 1], medium: 3, high: 1).isReachable)
    }

    /// The design's worked example: Rinat 2, Aino 2, Mira 1, Sam 1,
    /// bar at 4. "You and Aino together — or either of you plus both
    /// Mira and Sam."
    func test_theWorkedExample_enumeratesExactlyThoseCombinations() {
        let example = quorum(weights: [2, 2, 1, 1], medium: 4)
        let combinations = example.minimalCombinations(reaching: 4)
        let byWeight = combinations.map { $0.map(\.weight).sorted() }.sorted { $0.count < $1.count }

        XCTAssertTrue(byWeight.contains([2, 2]), "\(byWeight)")
        XCTAssertTrue(byWeight.contains([1, 1, 2]), "\(byWeight)")
        // And nothing that is merely a superset of one of those.
        XCTAssertFalse(byWeight.contains([1, 1, 2, 2]), "supersets are true and useless")
    }

    /// Minimal means minimal: no returned set can have a member removed
    /// and still clear the bar.
    func test_everyCombination_isMinimal() {
        let uneven = quorum(weights: [3, 2, 2, 1], medium: 4)
        for combination in uneven.minimalCombinations(reaching: 4) {
            let total = combination.reduce(UInt32(0)) { $0 + $1.weight }
            for dropped in combination {
                XCTAssertLessThan(
                    total - dropped.weight,
                    4,
                    "dropping \(dropped.weight) still clears the bar, so this set is not minimal"
                )
            }
        }
    }

    /// The fact someone reasons about when asked to give up weight:
    /// "right now no payment can happen without you or Aino".
    func test_aVeto_isVisibleAsNotBeingExcludable() {
        let balanced = quorum(weights: [2, 2, 1, 1], medium: 4)
        let mira = balanced.coSigners[2]
        XCTAssertTrue(balanced.canBeExcluded(mira), "Mira at 1 is not load-bearing")

        // One person's 3 is in every winning set.
        let dominant = quorum(weights: [3, 1, 1], medium: 4)
        XCTAssertFalse(dominant.canBeExcluded(dominant.coSigners[0]))
    }

    /// Requiring everyone is the setting that freezes the account the
    /// day one phone is lost, because a key cannot be removed without
    /// its own signature.
    func test_requiringEveryone_isDetected() {
        XCTAssertTrue(quorum(weights: [1, 1, 1], medium: 3).requiresEveryone)
        XCTAssertFalse(quorum(weights: [1, 1, 1], medium: 2).requiresEveryone)
    }

    /// Beyond the enumeration ceiling it answers with numbers rather
    /// than a sentence nobody could read — and must not hang doing it.
    func test_aLargeSignerSet_stopsEnumerating() {
        let many = quorum(weights: Array(repeating: 1, count: 15), medium: 8)
        XCTAssertTrue(many.isReachable)
        XCTAssertTrue(many.minimalCombinations(reaching: 8).isEmpty)
    }
}
