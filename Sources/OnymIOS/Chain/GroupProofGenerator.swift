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
/// `.tyranny` is wired in this slice — the other governance types
/// throw `notYetSupported`, which the UI surfaces as a clear "TBD"
/// message rather than a silent fallback.
protocol GroupProofGenerator: Sendable {
    func proveCreate(_ input: GroupProofCreateInput) throws -> GroupCreateProof
}

/// Inputs for a create-group proof. The caller (PR-C interactor) is
/// responsible for:
/// - lex-sorting `members` by `publicKeyCompressed` before computing
///   `adminIndex` (the SDK reuses the same sort to validate
///   `memberLeafHashes[adminIndex] == leafHash(adminBlsSecretKey)`),
/// - generating a fresh 32-byte salt via `GroupCommitmentBuilder.generateSalt`,
/// - choosing the tier based on the expected member count.
struct GroupProofCreateInput: Sendable {
    let groupType: SEPGroupType
    let tier: SEPTier
    /// Lex-sorted by `publicKeyCompressed`. The packed `leafHash`es
    /// land in the prover in this order.
    let members: [GovernanceMember]
    /// 32 bytes BE — the sender's own BLS Fr scalar.
    let adminBlsSecretKey: Data
    /// Position of the admin in `members` (after the lex sort).
    let adminIndex: Int
    /// 32-byte raw group ID — used directly as the `group_id_fr`
    /// per-group binding scalar in the Tyranny circuit.
    let groupID: Data
    /// 32 bytes; LE-mod-r in-circuit.
    let salt: Data
}

enum GroupProofGeneratorError: Error, Equatable, Sendable {
    case notYetSupported(SEPGroupType)
    case adminIndexOutOfRange(index: Int, count: Int)
    case sdkFailure(String)
}

struct OnymGroupProofGenerator: GroupProofGenerator {

    init() {}

    func proveCreate(_ input: GroupProofCreateInput) throws -> GroupCreateProof {
        switch input.groupType {
        case .tyranny:
            return try proveTyrannyCreate(input)
        case .anarchy, .oneOnOne, .democracy, .oligarchy:
            // PR-B ships Tyranny only — see `project_create_group_plan`
            // memory note. The other types stay stubbed until their own
            // slice; wiring them here without a UI to drive them just
            // accumulates dead code.
            throw GroupProofGeneratorError.notYetSupported(input.groupType)
        }
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
