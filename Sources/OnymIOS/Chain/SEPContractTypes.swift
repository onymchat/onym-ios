import Foundation

/// Mirrors `stellar-mls/swift-mls`'s `SEPGroupType` plus the post-v0.0.3
/// `tyranny` case that swift-mls hasn't been bumped for yet. Persisted as
/// the `group_type` u32 in the contract's `CommitmentEntryV2`.
enum SEPGroupType: UInt32, Codable, CaseIterable, Sendable {
    case anarchy = 0
    case oneOnOne = 1
    case democracy = 2
    case oligarchy = 3
    case tyranny = 4
}

/// Tier sizing for a Merkle tree commitment. Values pinned to match the
/// VK ceremonies.
enum SEPTier: Int, Codable, CaseIterable, Sendable {
    case small = 0
    case medium = 1
    case large = 2

    var maxMembers: Int {
        switch self {
        case .small: return 32
        case .medium: return 256
        case .large: return 2048
        }
    }

    var depth: Int {
        switch self {
        case .small: return 5
        case .medium: return 8
        case .large: return 11
        }
    }
}

/// Public-input bundle accompanying a Groth16 / PLONK proof: the new
/// commitment + the epoch number it lives at.
struct SEPPublicInputs: Codable, Equatable, Sendable {
    let commitment: Data
    let epoch: UInt64
}

/// Public-input bundle for the UpdateCircuit (#59 fix). The contract
/// rederives `cNew` from the proof itself, so the relayer no longer
/// trusts a client-supplied "new commitment". JSON keys use snake_case
/// to match the relayer payload schema.
struct SEPUpdatePublicInputs: Codable, Equatable, Sendable {
    let cOld: Data
    let epochOld: UInt64
    let cNew: Data

    enum CodingKeys: String, CodingKey {
        case cOld = "c_old"
        case epochOld = "epoch_old"
        case cNew = "c_new"
    }
}

/// Payload for `create_group_v2`. Used by Anarchy, 1v1, Democracy, AND
/// Tyranny (the latter not yet listed in swift-mls). Oligarchy uses its
/// own dedicated `SEPCreateOligarchyGroupRequest` because it seeds an
/// extra admin root.
struct SEPCreateGroupV2Request: Codable, Equatable, Sendable {
    let caller: String
    let groupID: Data
    let commitment: Data
    let tier: UInt32
    let groupType: SEPGroupType
    let memberCount: UInt32
    let proof: Data
    let publicInputs: SEPPublicInputs

    enum CodingKeys: String, CodingKey {
        case caller
        case groupID = "group_id"
        case commitment
        case tier
        case groupType = "group_type"
        case memberCount = "member_count"
        case proof
        case publicInputs = "public_inputs"
    }
}

/// Payload for `update_commitment` (member-add / member-remove).
struct SEPUpdateCommitmentRequest: Codable, Equatable, Sendable {
    let groupID: Data
    let proof: Data
    let publicInputs: SEPUpdatePublicInputs

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case proof
        case publicInputs = "public_inputs"
    }
}

/// Payload for `get_state` / `get_state_v2` / `get_admin_root`.
struct SEPGetStateRequest: Codable, Equatable, Sendable {
    let groupID: Data

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
    }
}

/// On-chain state returned by `get_state`. V1 entries (no group_type
/// metadata).
struct SEPCommitmentEntry: Codable, Equatable, Sendable {
    let commitment: Data
    let epoch: UInt64
    let timestamp: UInt64
    let tier: UInt32
    let active: Bool
}

/// Relayer's response to a contract-invocation POST. `accepted` reflects
/// the contract's verification result; `transactionHash` is set when a
/// Soroban tx was actually submitted.
struct SEPSubmissionResponse: Codable, Equatable, Sendable {
    let accepted: Bool
    let transactionHash: String?
    let message: String?
}

enum SEPError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse(statusCode: Int, body: String)
    case decodeFailure(String)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(statusCode, body):
            return "HTTP \(statusCode): \(body)"
        case let .decodeFailure(message):
            return "Decode failure: \(message)"
        }
    }
}
