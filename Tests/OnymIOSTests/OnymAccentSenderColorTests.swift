import XCTest
@testable import OnymIOS

/// Tests for the per-sender accent derivation that drives chat
/// sender-differentiation. The contract that matters:
///
///   - Deterministic: the same BLS pubkey always resolves to the same
///     accent (so a person's color is stable across devices, groups,
///     and launches — it's a visual fingerprint).
///   - Keyed on the pubkey alone: the function never sees the alias, so
///     an alias-spoofer can't steal the original's color.
///   - Spread across the palette: not a constant.
final class OnymAccentSenderColorTests: XCTestCase {

    func test_forSender_isDeterministic() {
        let hex = "ab".repeated(48)  // 96-char BLS pubkey hex
        let first = OnymAccent.forSender(blsPubkeyHex: hex)
        let second = OnymAccent.forSender(blsPubkeyHex: hex)
        XCTAssertEqual(first, second,
                       "same pubkey must always map to the same accent")
    }

    func test_forSender_distinctPubkeysCanDiffer() {
        // Generate a spread of pubkeys and confirm the mapping isn't a
        // constant — at least two distinct accents appear. (A perfect
        // even split isn't promised; non-degeneracy is.)
        let accents = Set((0..<200).map { i in
            OnymAccent.forSender(blsPubkeyHex: String(format: "%096x", i))
        })
        XCTAssertGreaterThan(accents.count, 1,
                             "the hash must distribute senders across the palette")
    }

    func test_forSender_alwaysReturnsPaletteMember() {
        let accent = OnymAccent.forSender(blsPubkeyHex: "ff".repeated(48))
        XCTAssertTrue(OnymAccent.allCases.contains(accent))
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
