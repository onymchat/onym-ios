import Foundation
import OnymSDK

/// Output of `GroupProofGenerator.proveCreate`. The relayer expects:
/// - `proof` — the **raw 1601-byte PLONK proof** (the relayer's
///   `decode_wire_bytes(_, _, Some(1601))` rejects anything else; the
///   `parsePlonkProof` trim happens on the contract side, not on the
///   wire).
/// - `publicInputs` — the SDK's full per-type PI bundle, split into
///   32-byte chunks. Tyranny create returns 4 chunks
///   (`commitment || Fr(0) || admin_pubkey_commitment || group_id_fr`)
///   which the relayer forwards as the contract's `Vec<BytesN<32>>`
///   public-inputs argument.
/// - `commitment` and `adminPubkeyCommitment` are convenience
///   accessors so callers don't have to re-slice the bundle.
struct GroupCreateProof: Equatable, Sendable {
    let proof: Data
    let publicInputs: [Data]

    /// First 32 bytes of the PI bundle — the new commitment the
    /// contract will store.
    var commitment: Data { publicInputs[0] }

    /// Bytes 64..96 of the PI bundle (Tyranny only) — the Poseidon
    /// commitment to the admin's BLS pubkey, surfaced separately
    /// because the relayer needs it both as a top-level CLI arg and
    /// as `publicInputs[2]`.
    var adminPubkeyCommitment: Data { publicInputs[2] }
}

/// PR-B's chain seam for proof generation. Switches on `groupType` so
/// that PR-C's interactor doesn't need to import OnymSDK directly. Only
/// `.tyranny` is wired for `proveUpdate` (PR 13a) — joiner admission
/// is admin-only by contract design.
protocol GroupProofGenerator: Sendable {
    func proveCreate(_ input: GroupProofCreateInput) throws -> GroupCreateProof
    /// Generate a Tyranny `update_commitment` proof for adding one
    /// member to an existing group's tree. Wraps
    /// `Tyranny.proveUpdate(...)` with the iOS calling convention.
    /// Throws `notYetSupported` for non-Tyranny group types.
    func proveUpdate(_ input: GroupProofUpdateInput) throws -> GroupUpdateProof
}

/// Output of `GroupProofGenerator.proveUpdate`. Same wire-shape
/// invariant as `GroupCreateProof`: relayer expects the raw
/// 1601-byte PLONK proof + the SDK's full PI bundle split into
/// 32-byte chunks. Tyranny update returns 5 chunks
/// (`c_old || epoch_old_be || c_new || admin_pubkey_commitment ||
/// group_id_fr`).
struct GroupUpdateProof: Equatable, Sendable {
    let proof: Data
    let publicInputs: [Data]

    /// Bytes 64..96 of the PI bundle — the new commitment the
    /// contract will store after verifying.
    var commitmentNew: Data { publicInputs[2] }
    /// `epoch_old + 1` — the epoch the contract advances to. The
    /// proof binds `epoch_old` (PI[1]); the new epoch is implicit
    /// in the contract's `update_commitment` arm.
    func epochNew(epochOld: UInt64) -> UInt64 { epochOld + 1 }
}

/// Inputs for a Tyranny update-commitment proof. Mirrors
/// `Tyranny.proveUpdate(...)`'s SDK shape.
///
/// - `oldMembers`: roster as it stands before the join (lex-sorted
///   by `publicKeyCompressed`). Admin's position determined from
///   this list.
/// - `adminBlsSecretKey`: 32-byte BE BLS Fr scalar.
/// - `adminIndexOld`: position of the admin's leaf in the OLD sorted
///   roster (the proof witnesses admin membership at that index).
/// - `epochOld`: current on-chain epoch.
/// - `memberRootNew`: 32-byte Poseidon root of the NEW tree
///   (post-join). Computed externally by the caller via
///   `Common.merkleRoot(...)`.
/// - `groupID`: 32-byte raw group ID (`group_id_fr` binding).
/// - `tier`: depth selector — must match the depth used at create
///   time + at every prior update for the proof to verify against
///   the correct VK.
/// - `saltOld` / `saltNew`: 32-byte fresh salts. `saltOld` was used
///   for the previous commitment; `saltNew` is freshly minted by
///   the admin per update to bind the new root.
struct GroupProofUpdateInput: Sendable {
    let groupType: SEPGroupType
    let tier: SEPTier
    let oldMembers: [GovernanceMember]
    let adminBlsSecretKey: Data
    let adminIndexOld: Int
    let epochOld: UInt64
    let memberRootNew: Data
    let groupID: Data
    let saltOld: Data
    let saltNew: Data
}

/// Inputs for a create-group proof. Per-type field requirements:
///
/// - **Tyranny**: needs `members` (lex-sorted by `publicKeyCompressed`),
///   `adminBlsSecretKey` (the device's own BLS Fr), `adminIndex`
///   (admin's position in the sorted roster), `groupID` (used as the
///   `group_id_fr` binding scalar), `tier`, `salt`.
/// - **OneOnOne**: needs `adminBlsSecretKey` (party 0 = creator) and
///   `peerBlsSecretKey` (party 1 = peer — the creator mints a fresh
///   ephemeral one and ships it inside the invitation envelope), plus
///   `salt`. `members` / `adminIndex` / `tier` / `groupID` are
///   ignored by the SDK call (groupID is still used as the contract's
///   storage-key arg, but doesn't bind into the proof). Both secrets
///   MUST differ — the SDK rejects `secretKey0 == secretKey1`.
struct GroupProofCreateInput: Sendable {
    let groupType: SEPGroupType
    let tier: SEPTier
    /// Lex-sorted by `publicKeyCompressed`. Tyranny-only.
    let members: [GovernanceMember]
    /// 32 bytes BE — the sender's own BLS Fr scalar.
    let adminBlsSecretKey: Data
    /// Position of the admin in `members` (after the lex sort).
    /// Tyranny-only.
    let adminIndex: Int
    /// 32-byte raw group ID — used directly as the `group_id_fr`
    /// per-group binding scalar in the Tyranny circuit.
    let groupID: Data
    /// 32 bytes; LE-mod-r in-circuit.
    let salt: Data
    /// 32 bytes BE — peer's BLS Fr scalar. **Required for OneOnOne**,
    /// nil for other types. The OneOnOne SDK rejects equal secrets,
    /// so the caller must mint a fresh ephemeral peer key (not reuse
    /// the device's BLS secret).
    var peerBlsSecretKey: Data? = nil
}

enum GroupProofGeneratorError: Error, Equatable, Sendable {
    case notYetSupported(SEPGroupType)
    case adminIndexOutOfRange(index: Int, count: Int)
    case missingPeerSecret
    case sdkFailure(String)
}

struct OnymGroupProofGenerator: GroupProofGenerator {

    init() {}

    func proveCreate(_ input: GroupProofCreateInput) throws -> GroupCreateProof {
        switch input.groupType {
        case .tyranny:
            return try proveTyrannyCreate(input)
        case .oneOnOne:
            return try proveOneOnOneCreate(input)
        case .anarchy:
            return try proveAnarchyCreate(input)
        case .democracy, .oligarchy:
            throw GroupProofGeneratorError.notYetSupported(input.groupType)
        }
    }

    func proveUpdate(_ input: GroupProofUpdateInput) throws -> GroupUpdateProof {
        switch input.groupType {
        case .tyranny:
            return try proveTyrannyUpdate(input)
        case .oneOnOne, .anarchy, .democracy, .oligarchy:
            // Only Tyranny supports admin-driven updates in this
            // PR. Anarchy will need its own arm later (any-member
            // update); OneOnOne is fixed 2-party.
            throw GroupProofGeneratorError.notYetSupported(input.groupType)
        }
    }

    private func proveTyrannyUpdate(_ input: GroupProofUpdateInput) throws -> GroupUpdateProof {
        guard input.adminIndexOld >= 0, input.adminIndexOld < input.oldMembers.count else {
            throw GroupProofGeneratorError.adminIndexOutOfRange(
                index: input.adminIndexOld,
                count: input.oldMembers.count
            )
        }
        var packedOld = Data(capacity: input.oldMembers.count * 32)
        for member in input.oldMembers {
            packedOld.append(member.leafHash)
        }

        let result: Tyranny.UpdateProof
        do {
            result = try Tyranny.proveUpdate(
                depth: input.tier.depth,
                memberLeafHashesOld: packedOld,
                adminSecretKey: input.adminBlsSecretKey,
                adminIndexOld: input.adminIndexOld,
                epochOld: input.epochOld,
                memberRootNew: input.memberRootNew,
                groupIdFr: input.groupID,
                saltOld: input.saltOld,
                saltNew: input.saltNew
            )
        } catch {
            throw GroupProofGeneratorError.sdkFailure(String(describing: error))
        }

        // PI bundle layout (`Tyranny.UpdateProof.publicInputs`, 160 B):
        //   c_old(32) || epoch_old_be(32) || c_new(32) ||
        //   admin_pubkey_commitment(32) || group_id_fr(32)
        // Each 32-byte chunk maps to one `BytesN<32>` in the contract's
        // 5-element `Vec<BytesN<32>>` public-inputs argument.
        let bundle = result.publicInputs
        guard bundle.count == 160 else {
            throw GroupProofGeneratorError.sdkFailure(
                "expected 160-byte update PI bundle, got \(bundle.count)"
            )
        }
        let chunks: [Data] = stride(from: 0, to: bundle.count, by: 32).map { offset in
            Data(bundle[offset..<(offset + 32)])
        }
        return GroupUpdateProof(proof: result.proof, publicInputs: chunks)
    }

    /// Anarchy create: there's no dedicated `proveCreate` SDK call —
    /// the founding ceremony is a regular membership proof at epoch 0
    /// over a single-member roster (just the creator). The contract's
    /// `create_group` arm verifies it as a membership proof and stores
    /// the resulting commitment as the group's epoch-0 anchor.
    private func proveAnarchyCreate(_ input: GroupProofCreateInput) throws -> GroupCreateProof {
        guard input.adminIndex >= 0, input.adminIndex < input.members.count else {
            // `adminIndex` is the prover's index for membership; field
            // name is shared with Tyranny but Anarchy has no admin
            // privileges — it's purely "which leaf am I".
            throw GroupProofGeneratorError.adminIndexOutOfRange(
                index: input.adminIndex,
                count: input.members.count
            )
        }
        var packedLeaves = Data(capacity: input.members.count * 32)
        for member in input.members {
            packedLeaves.append(member.leafHash)
        }

        let result: Anarchy.MembershipProof
        do {
            result = try Anarchy.proveMembership(
                depth: input.tier.depth,
                memberLeafHashes: packedLeaves,
                proverSecretKey: input.adminBlsSecretKey,
                proverIndex: input.adminIndex,
                epoch: 0,
                salt: input.salt
            )
        } catch {
            throw GroupProofGeneratorError.sdkFailure(String(describing: error))
        }

        // MembershipProof carries a single 32B commitment, not a bundled
        // PI blob. The contract expects `[commitment, Fr(0)]` as the
        // 2-element PI vector — same shape OneOnOne uses.
        let frZero = Data(repeating: 0, count: 32)
        return GroupCreateProof(
            proof: result.proof,
            publicInputs: [result.commitment, frZero]
        )
    }

    private func proveOneOnOneCreate(_ input: GroupProofCreateInput) throws -> GroupCreateProof {
        guard let peerSecret = input.peerBlsSecretKey else {
            throw GroupProofGeneratorError.missingPeerSecret
        }
        let result: OneOnOne.CreateProof
        do {
            result = try OneOnOne.proveCreate(
                secretKey0: input.adminBlsSecretKey,
                secretKey1: peerSecret,
                salt: input.salt
            )
        } catch {
            throw GroupProofGeneratorError.sdkFailure(String(describing: error))
        }
        // OneOnOne returns a single 32B commitment (not a bundled PI
        // blob). The contract's `create_membership_public_inputs`
        // expects 2 entries — `[commitment, Fr(0)]` — to match the
        // shared anarchy depth-5 membership-VK shape.
        let frZero = Data(repeating: 0, count: 32)
        return GroupCreateProof(
            proof: result.proof,
            publicInputs: [result.commitment, frZero]
        )
    }

    private func proveTyrannyCreate(_ input: GroupProofCreateInput) throws -> GroupCreateProof {
        guard input.adminIndex >= 0, input.adminIndex < input.members.count else {
            throw GroupProofGeneratorError.adminIndexOutOfRange(
                index: input.adminIndex,
                count: input.members.count
            )
        }
        var packedLeaves = Data(capacity: input.members.count * 32)
        for member in input.members {
            packedLeaves.append(member.leafHash)
        }

        let result: Tyranny.CreateProof
        do {
            result = try Tyranny.proveCreate(
                depth: input.tier.depth,
                memberLeafHashes: packedLeaves,
                adminSecretKey: input.adminBlsSecretKey,
                adminIndex: input.adminIndex,
                groupIdFr: input.groupID,
                salt: input.salt
            )
        } catch {
            throw GroupProofGeneratorError.sdkFailure(String(describing: error))
        }

        // SDK returns the raw 1601-byte proof. Don't `parsePlonkProof`
        // — the relayer rejects the trimmed form.
        // PI bundle layout (`Tyranny.CreateProof.publicInputs`, 128 B):
        //   commitment(32) || Fr(0)(32) || admin_pubkey_commitment(32) || group_id_fr(32)
        // Each 32-byte chunk maps to one `BytesN<32>` in the contract's
        // `Vec<BytesN<32>>` public-inputs argument.
        let bundle = result.publicInputs
        guard bundle.count == 128 else {
            throw GroupProofGeneratorError.sdkFailure(
                "expected 128-byte PI bundle, got \(bundle.count)"
            )
        }
        let chunks: [Data] = stride(from: 0, to: bundle.count, by: 32).map { offset in
            Data(bundle[offset..<(offset + 32)])
        }
        return GroupCreateProof(proof: result.proof, publicInputs: chunks)
    }
}
