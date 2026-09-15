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

    // MARK: - Usability
}
