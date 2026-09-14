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
            coSigners: weights.enumerated().compactMap {
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
        XCTAssertEqual(balanced.canBeExcluded(mira), true, "Mira at 1 is not load-bearing")

        // One person's 3 is in every winning set.
        let dominant = quorum(weights: [3, 1, 1], medium: 4)
        XCTAssertEqual(dominant.canBeExcluded(dominant.coSigners[0]), false)

        // Nil, not false, where nothing was computed: "no payment can
        // happen without you" is the strong claim and must not be
        // asserted about a set this never enumerated.
        let many = quorum(weights: Array(repeating: 1, count: 12), medium: 6)
        XCTAssertNil(many.canBeExcluded(many.coSigners[0]))
    }

    /// Unanimity is arithmetic, not equality.
    ///
    /// The first version tested `medium >= totalWeight`, which misses
    /// every uneven set: two signers at 2 with the bar at 3 need both
    /// signatures, and 3 >= 4 is false.
    func test_requiringEveryone_isArithmeticNotEquality() {
        XCTAssertTrue(quorum(weights: [1, 1, 1], medium: 3).requiresEveryone)
        XCTAssertFalse(quorum(weights: [1, 1, 1], medium: 2).requiresEveryone)
        XCTAssertTrue(
            quorum(weights: [2, 2], medium: 3).requiresEveryone,
            "both signatures are needed at 3 of 4, and equality never sees it"
        )
        XCTAssertFalse(quorum(weights: [3, 1], medium: 3).requiresEveryone)
    }

    /// The freeze is governed by the bar for *changing* the signer set,
    /// because that is what removing a lost key costs — and a key
    /// cannot be removed without its own signature.
    func test_theFreezeWarning_followsTheBarForChangingControl() {
        // Three at 1, spending needs 2, changing needs 3. Perfectly
        // ordinary to spend from, and already frozen: losing anyone
        // leaves 2, which can never reach 3 to remove them.
        let trap = quorum(weights: [1, 1, 1], medium: 2, high: 3)
        XCTAssertFalse(trap.requiresEveryone, "spending does not need everyone")
        XCTAssertEqual(
            trap.signersWhoseLossWouldFreezeIt.count,
            3,
            "losing any one of them makes removal impossible"
        )

        let safe = quorum(weights: [1, 1, 1, 1], medium: 2, high: 2)
        XCTAssertTrue(safe.signersWhoseLossWouldFreezeIt.isEmpty)
    }

    /// Not enumerated is not unreachable. A nine-signer treasury with a
    /// reachable bar must not be described as impossible.
    func test_aLargeSignerSet_isStillReachable() {
        let many = quorum(weights: Array(repeating: 1, count: 9), medium: 5)
        XCTAssertTrue(many.isReachable)
        XCTAssertFalse(many.isEnumerable)
        XCTAssertTrue(many.minimalCombinations(reaching: 5).isEmpty)
    }

    /// Zero is how Stellar spells removal, not a light co-signer.
    func test_aWeightOutsideTheRange_isRefusedRatherThanClamped() {
        XCTAssertNil(TreasuryCoSigner(account: account(9), weight: 0))
        XCTAssertNil(TreasuryCoSigner(account: account(9), weight: 256))
        XCTAssertEqual(TreasuryCoSigner(account: account(9), weight: 255)?.weight, 255)
        XCTAssertEqual(TreasuryCoSigner(account: account(9)).weight, 1)
    }

    /// Beyond the enumeration ceiling it answers with numbers rather
    /// than a sentence nobody could read — and must not hang doing it.
    func test_aVeryLargeSignerSet_stopsEnumerating() {
        let many = quorum(weights: Array(repeating: 1, count: 15), medium: 8)
        XCTAssertTrue(many.isReachable)
        XCTAssertTrue(many.minimalCombinations(reaching: 8).isEmpty)
    }
}
