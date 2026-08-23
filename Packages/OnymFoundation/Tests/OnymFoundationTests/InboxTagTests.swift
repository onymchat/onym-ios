import Foundation
import XCTest
@testable import OnymFoundation

/// Golden vector for the one formula behind every inbox route. Seven
/// call sites (senders, subscribers, the identity repository, push
/// registration) derive tags through `InboxTag.derive`; this pin is
/// what stands between them and a silent formula edit that would
/// re-route every inbox at once. The hex was computed by an
/// independent oracle (Python hashlib over
/// `SHA256("sep-inbox-v1" || key)[..8]`) — regenerate it there, never
/// by re-running the Swift under test.
final class InboxTagTests: XCTestCase {
    func testDeriveMatchesThePinnedVector() {
        let key = Data(0..<32) // 000102…1f
        XCTAssertEqual(InboxTag.derive(from: key), "fdee1b12aa915aa3")
    }

    func testDeriveOfEmptyKeyIsStillDomainSeparated() {
        // SHA256("sep-inbox-v1") — the prefix alone. Pinned so the
        // domain-separation string itself cannot drift unnoticed.
        XCTAssertEqual(InboxTag.derive(from: Data()), "064cb2d524b4d3fe")
    }
}
