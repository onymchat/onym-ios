import XCTest
@testable import OnymIOS
import OnymSDK

final class SmokeTests: XCTestCase {
    /// Smoke test: the OnymSDK SwiftPM dep links and the FFI is
    /// reachable from app code. Calls the cheapest function (a static
    /// pinned-VK SHA hex lookup) — no preprocess, no proving, just
    /// verifies the binaryTarget is wired to a working libOnymFFI.a.
    func test_onymSDKisReachableFromAppCode() throws {
        let hex = try Anarchy.pinnedMembershipVKSha256Hex(depth: 5)
        XCTAssertEqual(hex.count, 64, "pinned VK SHA-256 hex must be 64 chars")
        XCTAssertTrue(
            hex.allSatisfy { c in ("0"..."9").contains(c) || ("a"..."f").contains(c) },
            "got: \(hex)"
        )
    }
}
