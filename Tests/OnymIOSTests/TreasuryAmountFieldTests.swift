import XCTest
@testable import OnymIOS
import OnymStellar
import OnymTreasury

/// The amount field's half-typed states.
///
/// `TreasuryFlow` itself needs an `IdentityRepository`, a
/// `GroupRepository` and a broadcaster to construct, so what is tested
/// here is the logic that decides money, extracted to where it can be
/// reached. The parts that remain untested are the SwiftUI bindings.
final class TreasuryAmountFieldTests: XCTestCase {

    /// `StellarAmount(decimalString:)` refuses "" and "1.", which are
    /// both states a text field passes through on the way to a real
    /// number. Treating them as a parse failure made the funding
    /// breakdown vanish mid-keystroke and failed `create()` with
    /// "That isn't an amount" for an empty field, when "nothing
    /// spendable" is a perfectly ordinary thing to want.
    func test_halfTypedAmounts_readAsZeroOrTheirValue() throws {
        // The real implementation. The first version of this test
        // re-declared the logic locally, so it passed no matter what
        // the flow actually did — which is not a test.
        let spendable = TreasurySignerSelection.spendableAmount

        XCTAssertEqual(spendable("")?.stroops, 0)
        XCTAssertEqual(spendable("   ")?.stroops, 0)
        XCTAssertEqual(spendable(".")?.stroops, 0)
        XCTAssertEqual(spendable("1.")?.stroops, 10_000_000)
        XCTAssertEqual(spendable("10.5")?.stroops, 105_000_000)
        XCTAssertEqual(spendable("0")?.stroops, 0)
        // Still refuses things that aren't amounts at all.
        XCTAssertNil(spendable("abc"))
        XCTAssertNil(spendable("-1"))
    }
}
