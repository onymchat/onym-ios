import Foundation

/// On-chain governance flavour. The relayer (`onym-relayer/src/config.rs`,
/// `enum ContractType`) accepts the lowercase string spelling on the
/// wire — these `rawValue`s are pinned to match.
enum SEPGroupType: String, Codable, CaseIterable, Sendable {
    case anarchy
    case oneOnOne = "oneonone"
    case democracy
    case oligarchy
    case tyranny
}

/// Tier sizing for a Merkle tree commitment. Values pinned to match the
/// VK ceremonies. Wire-encoded as the raw `Int` for `--tier`.
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

/// Stellar network the relayer should target. Wire-encoded as the
/// lowercase label (`testnet` or `public`) — `mainnet` is also accepted
/// by the relayer as an alias for `public` but we always send `public`.
enum SEPNetwork: String, Codable, CaseIterable, Sendable {
    case testnet
    case publicNet = "public"
}

/// Generic envelope the relayer expects on `POST /`. Top-level shape
/// (mirrors `RelayerRequest` in `onym-relayer/src/handler.rs`):
///
/// ```json
/// {
///   "contractID":   "C…",
///   "contractType": "tyranny",
///   "network":      "testnet",
///   "function":     "create_group",
///   "payload":      { …function-specific… }
/// }
/// ```
///
/// Payloads are typed per function (e.g. `TyrannyCreateGroupPayload`)
/// and JSON-encoded with their own `CodingKeys`. JSONEncoder default
/// `Data` strategy is base64 — the relayer accepts both base64 and hex
/// (`decode_wire_bytes`), so byte fields round-trip without needing a
/// custom encoder.
struct SEPContractInvocation<Payload: Encodable & Sendable>: Encodable, Sendable {
    let contractID: String
    let contractType: SEPGroupType
    let network: SEPNetwork
    let function: String
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case contractID
        case contractType
        case network
        case function
        case payload
    }
}

/// `create_group` payload for the Tyranny contract. Differs from the
/// Anarchy / 1-on-1 / Democracy shape — Tyranny needs the Poseidon
/// `admin_pubkey_commitment` (32 B) as a separate CLI arg AND in the
/// 4-element public-inputs vector that the contract verifies.
///
/// The PI vector is sent as 4 `Data` elements (each 32 bytes,
/// JSON-encoded as base64 strings):
/// `[commitment, fr_zero (= 32 zero bytes), admin_pubkey_commitment, group_id_fr]`
/// — i.e. the SDK's 128-byte `Tyranny.CreateProof.publicInputs`
/// bundle split into 4 chunks. Relayer handler:
/// `build_public_inputs_from_object` → `ContractType::Tyranny` arm.
struct TyrannyCreateGroupPayload: Encodable, Equatable, Sendable {
    let groupID: Data
    let commitment: Data
    let tier: Int
    let adminPubkeyCommitment: Data
    /// 1601-byte raw PLONK proof — relayer's `decode_wire_bytes(_, _, Some(1601))`
    /// rejects anything else.
    let proof: Data
    /// 4 elements × 32 bytes — see comment above.
    let publicInputs: [Data]

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case commitment
        case tier
        case adminPubkeyCommitment = "admin_pubkey_commitment"
        case proof
        case publicInputs
    }
}

/// `update_commitment` payload — Tyranny variant. Same 4-element PI
/// shape as create, but the SDK's `Tyranny.UpdateProof.publicInputs`
/// is 160 bytes = 5 chunks (`c_old || epoch_old || c_new ||
/// admin_pubkey_commitment || group_id_fr`). Not used in PR-C; lives
/// here so the chain seam is complete.
struct TyrannyUpdateCommitmentPayload: Encodable, Equatable, Sendable {
    let groupID: Data
    let proof: Data
    let publicInputs: [Data]

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case proof
        case publicInputs
    }
}

/// Payload for `get_commitment`. The relayer's response is a JSON
/// object containing `commitment`, `epoch`, `timestamp`, `tier`,
/// `active` — captured by `SEPCommitmentEntry`.
struct GetCommitmentPayload: Encodable, Equatable, Sendable {
    let groupID: Data

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
    }
}

/// On-chain state returned by `get_commitment`.
struct SEPCommitmentEntry: Codable, Equatable, Sendable {
    let commitment: Data
    let epoch: UInt64
    let timestamp: UInt64
    let tier: UInt32
    let active: Bool
}

/// Relayer's response to a contract-invocation POST. Mirrors
/// `RelayerResponse` in `onym-relayer/src/handler.rs` — top-level
/// camelCase with optional `transactionHash` and `message`.
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
