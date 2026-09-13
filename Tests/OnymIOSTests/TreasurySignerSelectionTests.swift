import CryptoKit
import XCTest
@testable import OnymIOS
import OnymStellar
import OnymTreasury

/// The rules that decide a treasury's signer set and thresholds.
///
/// Extracted out of the creation flow specifically so they could be
/// tested: each case below is a way a founder could otherwise create an
/// account that is broken the moment it exists, and none of them can be
/// undone afterwards — undoing them needs the quorum that no longer
/// exists.
final class TreasurySignerSelectionTests: XCTestCase {

    private let ada = TreasurySignerSelectionTests.account(80)
    private let bo = TreasurySignerSelectionTests.account(81)
    private let cy = TreasurySignerSelectionTests.account(82)

    /// Deterministic accounts, seeded so a failure names the same one
    /// every run.
    private static func account(_ seed: UInt8) -> StellarAccountID {
        // swiftlint:disable:next force_try
        let key = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: seed, count: 32)
        )
        // swiftlint:disable:next force_try
        return try! StellarAccountID(publicKey: Data(key.publicKey.rawRepresentation))
    }

    // MARK: - Resolving who is actually a signer

    func test_onlyTickedAndNominatableMembersBecomeSigners() {
        let resolved = TreasurySignerSelection.accounts(
            ticked: ["a", "b"],
            from: [
                ("a", ada, true),
                ("b", bo, true),
                ("c", cy, true),      // not ticked
            ]
        )
        XCTAssertEqual(resolved, [ada, bo])
    }

    /// A member whose declaration stopped verifying — or who left the
    /// group — is not a signer, even while their tick survives. The
    /// transaction is built from the resolvable ones, so a threshold
    /// counted from the ticks would exceed the weight that exists.
    func test_aMemberWhoseDeclarationNoLongerVerifies_dropsOut() {
        let resolved = TreasurySignerSelection.accounts(
            ticked: ["a", "b"],
            from: [
                ("a", ada, true),
                ("b", bo, false),     // ticked, but no longer nominatable
            ]
        )
        XCTAssertEqual(resolved, [ada])
    }

    /// Two people naming the same address contribute one signer of
    /// weight one, not two. Counting heads instead would set a
    /// threshold the account can never reach.
    func test_twoMembersSharingAnAddress_countOnce() {
        let resolved = TreasurySignerSelection.accounts(
            ticked: ["a", "b"],
            from: [
                ("a", ada, true),
                ("b", ada, true),     // same wallet
            ]
        )
        XCTAssertEqual(resolved, [ada])
    }

    // MARK: - Thresholds

    /// The drain vector. The two steppers move independently, so
    /// "3 of 3 to spend, 1 of 3 to change who can spend" is two taps
    /// away — and any single co-signer could then setOptions themselves
    /// to sole control and spend everything.
    func test_highIsRaisedToMeetMedium() {
        let clamped = TreasurySignerSelection.clamped(
            TreasuryThresholds(low: 1, medium: 3, high: 1),
            signerCount: 3
        )
        XCTAssertEqual(clamped.medium, 3)
        XCTAssertEqual(clamped.high, 3, "a minority must not be able to seize the account")
    }

    /// A threshold above the total weight is an account no quorum can
    /// ever act on — including to fix the threshold.
    func test_neitherThresholdMayExceedTheSignerCount() {
        let clamped = TreasurySignerSelection.clamped(
            TreasuryThresholds(low: 9, medium: 9, high: 9),
            signerCount: 2
        )
        XCTAssertEqual(clamped.low, 2)
        XCTAssertEqual(clamped.medium, 2)
        XCTAssertEqual(clamped.high, 2)
    }

    func test_thresholdsAreNeverZero() {
        let clamped = TreasurySignerSelection.clamped(
            TreasuryThresholds(low: 0, medium: 0, high: 0),
            signerCount: 3
        )
        XCTAssertEqual(clamped.low, 1)
        XCTAssertEqual(clamped.medium, 1)
        XCTAssertEqual(clamped.high, 1)
    }

    func test_aSensibleSettingIsLeftAlone() {
        let original = TreasuryThresholds(low: 1, medium: 2, high: 3)
        XCTAssertEqual(
            TreasurySignerSelection.clamped(original, signerCount: 3),
            original
        )
    }

    // MARK: - Usability

    func test_usabilityRejectsWhatWouldDeadlockOrBeSeizable() {
        XCTAssertTrue(TreasurySignerSelection.isUsable(
            TreasuryThresholds(low: 1, medium: 2, high: 2), signerCount: 3
        ))
        // More signatures required than signers exist.
        XCTAssertFalse(TreasurySignerSelection.isUsable(
            TreasuryThresholds(low: 1, medium: 4, high: 4), signerCount: 3
        ))
        // Control cheaper than spending.
        XCTAssertFalse(TreasurySignerSelection.isUsable(
            TreasuryThresholds(low: 1, medium: 3, high: 1), signerCount: 3
        ))
        // Nobody at all.
        XCTAssertFalse(TreasurySignerSelection.isUsable(
            TreasuryThresholds(low: 1, medium: 1, high: 1), signerCount: 0
        ))
    }

    /// The default offered on screen must itself be usable, for any
    /// group size.
    func test_theDefaultMajorityIsAlwaysUsable() {
        for count in 1...12 {
            let defaults = TreasuryThresholds.majority(of: count)
            XCTAssertTrue(
                TreasurySignerSelection.isUsable(defaults, signerCount: count),
                "majority of \(count) is not usable"
            )
        }
    }
}
