import XCTest
@testable import OnymDesign

/// `forSender` is the one piece of colour *policy* in the design layer:
/// it turns an identity into an accent. It stays in OnymDesign rather
/// than the token package precisely so adopters inherit it, which makes
/// its guarantees worth pinning.
final class SenderAccentTests: XCTestCase {

    private let alice = "8f14e45fceea167a5a36dedd4bea2543"
    private let bob   = "c9f0f895fb98ab9159f51fd0297e236d"

    func testSameKeyAlwaysResolvesToTheSameAccent() {
        // Colour has to survive a relaunch and agree across devices, so
        // the mapping cannot lean on Hashable's per-process seed.
        let first = OnymAccent.forSender(blsPubkeyHex: alice)
        for _ in 0..<50 {
            XCTAssertEqual(OnymAccent.forSender(blsPubkeyHex: alice), first)
        }
    }

    func testEveryByteOfTheKeyFeedsTheMapping() {
        // Two members can both call themselves Alice; the colour has to
        // come from the pubkey, all of it. If a suffix were ignored,
        // keys sharing a prefix would always share a colour — and an
        // impostor could shop for one that matches their target.
        //
        // Six colours means two arbitrary keys collide about one time
        // in six, so this asks the sharper question: does changing a
        // single character anywhere in the key ever move the colour?
        for position in 0..<alice.count {
            var moved = false
            for digit in "0123456789abcdef" {
                var chars = Array(alice)
                if chars[position] == digit { continue }
                chars[position] = digit
                if OnymAccent.forSender(blsPubkeyHex: String(chars))
                    != OnymAccent.forSender(blsPubkeyHex: alice) {
                    moved = true
                    break
                }
            }
            XCTAssertTrue(moved, "character \(position) never affects the accent")
        }
    }

    func testTwoDistinctKeysCanDiffer() {
        // Not a guarantee about any particular pair — with six colours,
        // collisions are expected and fine. This only pins that the
        // mapping is not constant.
        XCTAssertGreaterThan(
            Set([alice, bob, "deadbeef", "0011223344556677"]
                .map { OnymAccent.forSender(blsPubkeyHex: $0) }).count,
            1
        )
    }

    func testEveryAccentIsReachable() {
        // A mapping that can only ever produce three of six colours
        // would make groups look monotonous and would not be obvious
        // from any single conversation.
        var seen = Set<OnymAccent>()
        for i in 0..<2000 {
            seen.insert(OnymAccent.forSender(blsPubkeyHex: String(format: "%064x", i)))
        }
        XCTAssertEqual(seen.count, OnymAccent.allCases.count,
                       "unreachable accents: \(Set(OnymAccent.allCases).subtracting(seen))")
    }

    func testDistributionIsNotBadlySkewed() {
        // FNV-1a over hex bytes should spread roughly evenly. A wildly
        // uneven split would mean most people share one colour.
        var tally: [OnymAccent: Int] = [:]
        let n = 6000
        for i in 0..<n {
            tally[OnymAccent.forSender(blsPubkeyHex: String(format: "%064x", i)), default: 0] += 1
        }
        let expected = n / OnymAccent.allCases.count
        for (accent, count) in tally {
            XCTAssertLessThan(
                abs(count - expected), expected / 2,
                "\(accent.rawValue) got \(count) of \(n), expected near \(expected)"
            )
        }
    }

    func testEmptyKeyDoesNotTrap() {
        // Defensive: a member with no key yet still has to render.
        XCTAssertNoThrow(OnymAccent.forSender(blsPubkeyHex: ""))
    }
}
