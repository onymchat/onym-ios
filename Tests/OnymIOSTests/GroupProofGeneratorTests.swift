import XCTest
import OnymSDK
@testable import OnymIOS

/// Real proof generation against the OnymSDK Tyranny circuit. The tier
/// is `.small` (depth 5) — fastest to prove (~1s on the simulator) but
/// still goes through the full circuit so the byte sizes asserted here
/// would catch any drift in `Tyranny.CreateProof.publicInputs` layout.
final class GroupProofGeneratorTests: XCTestCase {

    func test_proveCreate_tyranny_returnsParsedProofAndCommitment() throws {
        let secrets = (1...3).map(fr)
        let members = try secrets.map { sk in
            GovernanceMember(
                publicKeyCompressed: try Common.publicKey(secretKey: sk),
                leafHash: try Common.leafHash(secretKey: sk)
            )
        }
        let sorted = members.sorted { lhs, rhs in
            lhs.publicKeyCompressed.lexicographicallyPrecedes(rhs.publicKeyCompressed)
        }
        let adminSecret = secrets[0]
        let adminLeaf = try Common.leafHash(secretKey: adminSecret)
        let adminIndex = sorted.firstIndex(where: { $0.leafHash == adminLeaf })!

        let input = GroupProofCreateInput(
            groupType: .tyranny,
            tier: .small,
            members: sorted,
            adminBlsSecretKey: adminSecret,
            adminIndex: adminIndex,
            groupID: fr(0x7777),
            salt: Data(repeating: 0xEE, count: 32)
        )

        let result = try OnymGroupProofGenerator().proveCreate(input)
        XCTAssertEqual(result.proof.count, 1568, "Common.parsePlonkProof trims the 1601-byte raw output")
        XCTAssertEqual(result.publicInputs.commitment.count, 32)
        XCTAssertEqual(result.publicInputs.epoch, 0, "create-group is always epoch 0")
    }

    func test_proveCreate_anarchy_throwsNotYetSupported() {
        let input = stubInput(groupType: .anarchy)
        XCTAssertThrowsError(try OnymGroupProofGenerator().proveCreate(input)) { error in
            XCTAssertEqual(
                error as? GroupProofGeneratorError,
                .notYetSupported(.anarchy)
            )
        }
    }

    func test_proveCreate_oneOnOne_throwsNotYetSupported() {
        let input = stubInput(groupType: .oneOnOne)
        XCTAssertThrowsError(try OnymGroupProofGenerator().proveCreate(input)) { error in
            XCTAssertEqual(
                error as? GroupProofGeneratorError,
                .notYetSupported(.oneOnOne)
            )
        }
    }

    func test_proveCreate_adminIndexOutOfRange_throws() {
        let input = GroupProofCreateInput(
            groupType: .tyranny,
            tier: .small,
            members: [
                GovernanceMember(
                    publicKeyCompressed: Data(repeating: 0xAA, count: 48),
                    leafHash: Data(repeating: 0xBB, count: 32)
                )
            ],
            adminBlsSecretKey: Data(repeating: 0x01, count: 32),
            adminIndex: 5,
            groupID: Data(repeating: 0, count: 32),
            salt: Data(repeating: 0, count: 32)
        )
        XCTAssertThrowsError(try OnymGroupProofGenerator().proveCreate(input)) { error in
            XCTAssertEqual(
                error as? GroupProofGeneratorError,
                .adminIndexOutOfRange(index: 5, count: 1)
            )
        }
    }

    // MARK: - Helpers

    private func stubInput(groupType: SEPGroupType) -> GroupProofCreateInput {
        GroupProofCreateInput(
            groupType: groupType,
            tier: .small,
            members: [],
            adminBlsSecretKey: Data(repeating: 0x01, count: 32),
            adminIndex: 0,
            groupID: Data(repeating: 0, count: 32),
            salt: Data(repeating: 0, count: 32)
        )
    }

    /// 32-byte BE encoding of a small u64 — copied from the OnymSDK
    /// test helpers, can't import them here.
    private func fr(_ value: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            bytes[31 - i] = UInt8((value >> (i * 8)) & 0xFF)
        }
        return Data(bytes)
    }
}
