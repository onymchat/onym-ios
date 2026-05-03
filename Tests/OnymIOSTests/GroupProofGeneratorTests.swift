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
        XCTAssertEqual(result.proof.count, 1601,
                       "relayer expects the raw 1601-byte plonk proof — no parsePlonkProof on the wire")
        XCTAssertEqual(result.publicInputs.count, 4,
                       "Tyranny PI bundle splits into 4 × 32-byte chunks (commitment + Fr(0) + admin_pkc + group_id_fr)")
        for (i, chunk) in result.publicInputs.enumerated() {
            XCTAssertEqual(chunk.count, 32, "PI chunk #\(i) must be 32 bytes")
        }
        XCTAssertEqual(result.commitment, result.publicInputs[0])
        XCTAssertEqual(result.adminPubkeyCommitment, result.publicInputs[2])
    }

    func test_proveCreate_anarchy_returnsRawProofAnd2ElementPI() throws {
        // Founding ceremony: single-member roster (the creator).
        // Anarchy uses the membership circuit at epoch 0 — no admin
        // privileges, no group_id_fr binding.
        let creatorSecret = fr(1)
        let creatorMember = try GovernanceMember(
            publicKeyCompressed: Common.publicKey(secretKey: creatorSecret),
            leafHash: Common.leafHash(secretKey: creatorSecret)
        )
        let input = GroupProofCreateInput(
            groupType: .anarchy,
            tier: .small,
            members: [creatorMember],
            adminBlsSecretKey: creatorSecret,
            adminIndex: 0,                  // creator's leaf position
            groupID: Data(repeating: 0xAB, count: 32),  // not bound into proof
            salt: Data(repeating: 0xEE, count: 32)
        )
        let result = try OnymGroupProofGenerator().proveCreate(input)
        XCTAssertEqual(result.proof.count, 1601,
                       "Anarchy returns the same raw 1601-byte plonk proof as Tyranny / 1-on-1")
        XCTAssertEqual(result.publicInputs.count, 2,
                       "Anarchy PI = [commitment, Fr(0)] — 2 entries")
        XCTAssertEqual(result.publicInputs[0].count, 32)
        XCTAssertEqual(result.publicInputs[1], Data(repeating: 0, count: 32),
                       "Fr(0) tail must be 32 zero bytes")
    }

    func test_proveCreate_anarchy_proverIndexOutOfRange_throws() {
        let input = GroupProofCreateInput(
            groupType: .anarchy,
            tier: .small,
            members: [],   // empty roster — index 0 is out of range
            adminBlsSecretKey: fr(1),
            adminIndex: 0,
            groupID: Data(repeating: 0, count: 32),
            salt: Data(repeating: 0, count: 32)
        )
        XCTAssertThrowsError(try OnymGroupProofGenerator().proveCreate(input)) { error in
            XCTAssertEqual(
                error as? GroupProofGeneratorError,
                .adminIndexOutOfRange(index: 0, count: 0)
            )
        }
    }

    func test_proveCreate_oneOnOne_returnsRawProofAnd2ElementPI() throws {
        // Two distinct BLS Fr scalars (the SDK rejects equal secrets).
        let input = GroupProofCreateInput(
            groupType: .oneOnOne,
            tier: .small,                     // ignored for oneOnOne
            members: [],                      // ignored for oneOnOne
            adminBlsSecretKey: fr(1),
            adminIndex: 0,                    // ignored for oneOnOne
            groupID: Data(repeating: 0, count: 32),
            salt: Data(repeating: 0xEE, count: 32),
            peerBlsSecretKey: fr(2)
        )
        let result = try OnymGroupProofGenerator().proveCreate(input)
        XCTAssertEqual(result.proof.count, 1601,
                       "OneOnOne returns the same raw 1601-byte plonk proof as Tyranny")
        XCTAssertEqual(result.publicInputs.count, 2,
                       "OneOnOne PI = [commitment, Fr(0)] — 2 entries")
        XCTAssertEqual(result.publicInputs[0].count, 32)
        XCTAssertEqual(result.publicInputs[1], Data(repeating: 0, count: 32),
                       "Fr(0) tail must be 32 zero bytes")
    }

    func test_proveCreate_oneOnOne_missingPeerSecret_throws() {
        let input = stubInput(groupType: .oneOnOne)   // no peerBlsSecretKey
        XCTAssertThrowsError(try OnymGroupProofGenerator().proveCreate(input)) { error in
            XCTAssertEqual(error as? GroupProofGeneratorError, .missingPeerSecret)
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
