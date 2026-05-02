import CryptoKit
import Foundation
import OnymSDK

/// Thin wrapper around `OnymSDK.Common` that speaks `GovernanceMember`
/// rather than raw byte buffers. Mirrors `SEPCommitmentBuilder` in
/// `swift-mls` so cross-platform behaviour (and test vectors) stays
/// aligned.
///
/// All FFI calls run synchronously — the heavy work is hashing, not
/// proving, so they're fine on the actor that owns the group state.
enum GroupCommitmentBuilder {

    /// Fresh 32-byte salt for a brand-new group. Random bytes; the
    /// circuit interprets them little-endian-mod-r in-circuit.
    static func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }

    /// Deterministic salt rotation for member-add events.
    /// `SHA256(previousSalt || memberKey)` — both sides of a
    /// `SEPMemberJoined` derive the same salt and therefore the same
    /// epoch's encryption key, so observers don't fork.
    static func deriveSalt(previousSalt: Data, memberKey: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: previousSalt)
        hasher.update(data: memberKey)
        return Data(hasher.finalize())
    }

    /// 32-byte Poseidon leaf hash for a single member's BLS Fr secret.
    static func computeLeafHash(secretKey: Data) throws -> Data {
        try Common.leafHash(secretKey: secretKey)
    }

    /// 48-byte arkworks-compressed G1 BLS public key for a 32-byte
    /// secret. Used to compute the stable `publicKeyCompressed` on
    /// `GovernanceMember`.
    static func computePublicKey(secretKey: Data) throws -> Data {
        try Common.publicKey(secretKey: secretKey)
    }

    /// Sort `members` lex by `publicKeyCompressed`, pack the
    /// `leafHash` bytes, pad to `2^depth` with `Fr::ZERO`, and ask
    /// OnymSDK for the Poseidon Merkle root.
    ///
    /// The lex sort matches SEP-XXXX §2.1 — both peers MUST sort
    /// identically before computing roots, otherwise commitments
    /// diverge.
    static func computeMerkleRoot(
        members: [GovernanceMember],
        tier: SEPTier
    ) throws -> Data {
        let sorted = members.sorted { lhs, rhs in
            lhs.publicKeyCompressed.lexicographicallyPrecedes(rhs.publicKeyCompressed)
        }
        var packed = Data(capacity: sorted.count * 32)
        for member in sorted {
            packed.append(member.leafHash)
        }
        return try Common.merkleRoot(leafHashes: packed, depth: tier.depth)
    }

    /// `Poseidon(Poseidon(root, Fr(epoch)), salt_fr)`. The plonk-era
    /// commitment shape used by every sep-* contract.
    static func computePoseidonCommitment(
        poseidonRoot: Data,
        epoch: UInt64,
        salt: Data
    ) throws -> Data {
        try Common.poseidonCommitment(
            poseidonRoot: poseidonRoot,
            epoch: epoch,
            salt: salt
        )
    }
}
