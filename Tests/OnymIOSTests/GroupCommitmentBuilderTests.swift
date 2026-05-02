import CryptoKit
import XCTest
@testable import OnymIOS

/// Unit tests for `GroupCommitmentBuilder`. The pure-Swift helpers
/// (salt generation + derivation) are exercised directly; the FFI-
/// backed leaf / merkle / commitment helpers go through `OnymSDK` and
/// just verify they round-trip and produce stable byte counts — the
/// underlying cryptography is the SDK's responsibility, not this
/// wrapper's.
final class GroupCommitmentBuilderTests: XCTestCase {

    func test_generateSalt_returns32RandomBytes() {
        let a = GroupCommitmentBuilder.generateSalt()
        let b = GroupCommitmentBuilder.generateSalt()
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(b.count, 32)
        XCTAssertNotEqual(a, b, "two consecutive calls must produce different salts")
    }

    func test_deriveSalt_isDeterministic_andMatchesSHA256() {
        let prev = Data(repeating: 0xAA, count: 32)
        let memberKey = Data(repeating: 0xBB, count: 48)

        let derived1 = GroupCommitmentBuilder.deriveSalt(previousSalt: prev, memberKey: memberKey)
        let derived2 = GroupCommitmentBuilder.deriveSalt(previousSalt: prev, memberKey: memberKey)
        XCTAssertEqual(derived1, derived2, "deterministic for the same inputs")

        var hasher = CryptoKit.SHA256()
        hasher.update(data: prev)
        hasher.update(data: memberKey)
        XCTAssertEqual(derived1, Data(hasher.finalize()))
    }

    func test_deriveSalt_differentInputsDiverge() {
        let prev = Data(repeating: 0xAA, count: 32)
        let m1 = Data(repeating: 0x01, count: 48)
        let m2 = Data(repeating: 0x02, count: 48)
        XCTAssertNotEqual(
            GroupCommitmentBuilder.deriveSalt(previousSalt: prev, memberKey: m1),
            GroupCommitmentBuilder.deriveSalt(previousSalt: prev, memberKey: m2)
        )
    }

    func test_computePublicKeyAndLeafHash_returnExpectedSizes() throws {
        let secret = Data(repeating: 0x42, count: 32)
        let pub = try GroupCommitmentBuilder.computePublicKey(secretKey: secret)
        let leaf = try GroupCommitmentBuilder.computeLeafHash(secretKey: secret)
        XCTAssertEqual(pub.count, 48, "compressed BLS12-381 G1 is 48 bytes")
        XCTAssertEqual(leaf.count, 32, "Poseidon Fr leaf is 32 bytes")
    }

    func test_computeMerkleRoot_isOrderInvariant() throws {
        // Lex-sort behaviour: building the same roster in two orders
        // must produce the same Poseidon root.
        let a = try memberFromSecret(Data(repeating: 0x10, count: 32))
        let b = try memberFromSecret(Data(repeating: 0x20, count: 32))
        let c = try memberFromSecret(Data(repeating: 0x30, count: 32))

        let root1 = try GroupCommitmentBuilder.computeMerkleRoot(
            members: [a, b, c],
            tier: .small
        )
        let root2 = try GroupCommitmentBuilder.computeMerkleRoot(
            members: [c, a, b],
            tier: .small
        )
        XCTAssertEqual(root1, root2)
        XCTAssertEqual(root1.count, 32)
    }

    func test_computePoseidonCommitment_changesWithEpoch() throws {
        let member = try memberFromSecret(Data(repeating: 0x42, count: 32))
        let root = try GroupCommitmentBuilder.computeMerkleRoot(
            members: [member],
            tier: .small
        )
        let salt = Data(repeating: 0x77, count: 32)

        let c0 = try GroupCommitmentBuilder.computePoseidonCommitment(
            poseidonRoot: root,
            epoch: 0,
            salt: salt
        )
        let c1 = try GroupCommitmentBuilder.computePoseidonCommitment(
            poseidonRoot: root,
            epoch: 1,
            salt: salt
        )
        XCTAssertEqual(c0.count, 32)
        XCTAssertNotEqual(c0, c1, "epoch participates in the commitment")
    }

    // MARK: - Helpers

    private func memberFromSecret(_ secret: Data) throws -> GovernanceMember {
        GovernanceMember(
            publicKeyCompressed: try GroupCommitmentBuilder.computePublicKey(secretKey: secret),
            leafHash: try GroupCommitmentBuilder.computeLeafHash(secretKey: secret)
        )
    }
}
