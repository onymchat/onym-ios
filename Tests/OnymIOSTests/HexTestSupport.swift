import Foundation

/// Hex → `Data`, for tests.
///
/// There were three private copies of this in the target
/// (`MediaCommitmentFixtureTests`, `GroupRulesVectorTests`,
/// `GroupRulesStandingTests`) and each one was a place the next fixture
/// would grow a fourth.
///
/// Deliberately *not* `ChatGroup.bytes(fromHex:)`. These tests check
/// documents and fixtures produced by the code under test, and reading
/// them back with that same code would let a shared bug agree with
/// itself. This is a second implementation on purpose, and it is
/// strict where the production one is lenient: an odd length or a
/// non-hex character is nil rather than a silently shorter `Data`.
extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
