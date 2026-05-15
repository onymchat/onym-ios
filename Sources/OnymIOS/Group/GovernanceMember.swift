import Foundation

/// One member-leaf entry in a group's roster. The two byte arrays are
/// derived from the same 32-byte BLS Fr secret:
///
/// - `publicKeyCompressed` — 48 bytes, arkworks-compressed G1Affine
///   (`[sk] · G`). Used for Merkle-tree leaf ordering (lex sort) and as
///   the stable on-the-wire identifier of a member across epochs.
/// - `leafHash` — 32 bytes, `Poseidon(sk_fr)`. The actual scalar that
///   lands in the Poseidon Merkle tree the contract verifies against.
///
/// Mirrors `SEPGroupMemberLeaf` from `swift-mls`.
struct GovernanceMember: Codable, Equatable, Sendable {
    let publicKeyCompressed: Data
    let leafHash: Data

    enum CodingKeys: String, CodingKey {
        case publicKeyCompressed = "public_key_compressed"
        case leafHash = "leaf_hash"
    }
}
