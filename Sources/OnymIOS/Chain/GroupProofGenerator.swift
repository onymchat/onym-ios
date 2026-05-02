import Foundation
import OnymSDK

/// Output of `GroupProofGenerator.proveCreate`. The relayer / contract
/// expect:
/// - `proof` — 1568 bytes, the `Common.parsePlonkProof`-trimmed form of
///   the raw 1601-byte SDK output (strips the four `len()` u64
///   prefixes + the trailing `plookup_proof: None` byte).
/// - `publicInputs` — the `(commitment, epoch)` pair the
///   `SEPCreateGroupV2Request` carries. For create the SDK's
///   per-type-specific PI bundle (`commitment || Fr(0) || …`) is sliced
///   to its first 32 bytes for the commitment; epoch is always 0 for
///   create.
struct GroupCreateProof: Equatable, Sendable {
    let proof: Data
    let publicInputs: SEPPublicInputs
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

        let parsed: Data
        do {
            parsed = try Common.parsePlonkProof(result.proof)
        } catch {
            throw GroupProofGeneratorError.sdkFailure(String(describing: error))
        }

        // PI bundle layout (Tyranny.CreateProof):
        //   commitment(32) || Fr(0)(32) || admin_pubkey_commitment(32) || group_id_fr(32)
        // Only the first 32 bytes (commitment) cross the wire; the rest
        // are bound by the proof itself.
        let commitment = result.publicInputs.prefix(32)
        return GroupCreateProof(
            proof: parsed,
            publicInputs: SEPPublicInputs(commitment: Data(commitment), epoch: 0)
        )
    }
}
