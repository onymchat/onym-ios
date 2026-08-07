import Foundation

/// On-chain governance flavour. The relayer (`onym-relayer/src/config.rs`,
/// `enum ContractType`) accepts the lowercase string spelling on the
/// wire — these `rawValue`s are pinned to match.
public enum SEPGroupType: String, Codable, CaseIterable, Sendable {
    case anarchy
    case oneOnOne = "oneonone"
    case democracy
    case oligarchy
    case tyranny
}

/// Tier sizing for a Merkle tree commitment. Values pinned to match the
/// VK ceremonies. Wire-encoded as the raw `Int` for `--tier`.
public enum SEPTier: Int, Codable, CaseIterable, Sendable {
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

    public var depth: Int {
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
public enum SEPNetwork: String, Codable, CaseIterable, Sendable {
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
public struct SEPContractInvocation<Payload: Encodable & Sendable>: Encodable, Sendable {
    let contractID: String
    let contractType: SEPGroupType
    let network: SEPNetwork
    public let function: String
    public let payload: Payload

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
public struct TyrannyCreateGroupPayload: Encodable, Equatable, Sendable {
    let groupID: Data
    let commitment: Data
    let tier: Int
    let adminPubkeyCommitment: Data
    /// 1601-byte raw PLONK proof — relayer's `decode_wire_bytes(_, _, Some(1601))`
    /// rejects anything else.
    let proof: Data
    /// 4 elements × 32 bytes — see comment above.
    let publicInputs: [Data]

    public init(
        groupID: Data,
        commitment: Data,
        tier: Int,
        adminPubkeyCommitment: Data,
        proof: Data,
        publicInputs: [Data]
    ) {
        self.groupID = groupID
        self.commitment = commitment
        self.tier = tier
        self.adminPubkeyCommitment = adminPubkeyCommitment
        self.proof = proof
        self.publicInputs = publicInputs
    }

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case commitment
        case tier
        case adminPubkeyCommitment = "admin_pubkey_commitment"
        case proof
        case publicInputs
    }
}

/// `create_group` payload for the OneOnOne (1v1) contract. Simpler
/// than Tyranny — no tier (1v1 is fixed at depth 5, exactly 2
/// members), no admin_pubkey_commitment. The `publicInputs` vector
/// is the standard membership-style 2-element form
/// `[commitment, Fr(0)]` that the contract's
/// `create_membership_public_inputs` expects.
///
/// Relayer handler: `add_create_group_args` →
/// `ContractType::OneOnOne` arm.
public struct OneOnOneCreateGroupPayload: Encodable, Equatable, Sendable {
    let groupID: Data
    let commitment: Data
    /// 1601-byte raw PLONK proof — same constraint as Tyranny.
    let proof: Data
    /// 2 elements × 32 bytes — `[commitment, Fr(0)]`.
    let publicInputs: [Data]

    public init(groupID: Data, commitment: Data, proof: Data, publicInputs: [Data]) {
        self.groupID = groupID
        self.commitment = commitment
        self.proof = proof
        self.publicInputs = publicInputs
    }

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case commitment
        case proof
        case publicInputs
    }
}

/// `create_group` payload for the Anarchy contract. Membership-style
/// 2-element PI like OneOnOne, but adds `tier` (selects the membership
/// VK + tree depth) and `member_count` (informational — the contract
/// stores it but doesn't validate; sentinel `0` means "not tracked").
/// No admin field — Anarchy gives all members equal control.
///
/// Relayer handler: `add_create_group_args` → `ContractType::Anarchy`
/// arm (tier + member_count → `--tier` / `--member-count` CLI flags).
/// Contract: `sep-anarchy/src/lib.rs::create_group` (lines 347–410).
public struct AnarchyCreateGroupPayload: Encodable, Equatable, Sendable {
    let groupID: Data
    let commitment: Data
    let tier: Int
    /// Roster size at create time — `1` for a creator-only founding,
    /// growing later via `update_commitment`. The contract accepts any
    /// value without validation; we always send the real count.
    let memberCount: Int
    /// 1601-byte raw PLONK proof — same constraint as Tyranny / 1-on-1.
    let proof: Data
    /// 2 elements × 32 bytes — `[commitment, Fr(0)]`.
    let publicInputs: [Data]

    public init(
        groupID: Data,
        commitment: Data,
        tier: Int,
        memberCount: Int,
        proof: Data,
        publicInputs: [Data]
    ) {
        self.groupID = groupID
        self.commitment = commitment
        self.tier = tier
        self.memberCount = memberCount
        self.proof = proof
        self.publicInputs = publicInputs
    }

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case commitment
        case tier
        case memberCount = "member_count"
        case proof
        case publicInputs
    }
}

/// `update_commitment` payload — Tyranny variant. Same 4-element PI
/// shape as create, but the SDK's `Tyranny.UpdateProof.publicInputs`
/// is 160 bytes = 5 chunks (`c_old || epoch_old || c_new ||
/// admin_pubkey_commitment || group_id_fr`). Not used in PR-C; lives
/// here so the chain seam is complete.
public struct TyrannyUpdateCommitmentPayload: Encodable, Equatable, Sendable {
    let groupID: Data
    let proof: Data
    let publicInputs: [Data]

    public init(groupID: Data, proof: Data, publicInputs: [Data]) {
        self.groupID = groupID
        self.proof = proof
        self.publicInputs = publicInputs
    }

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

/// On-chain state returned by `get_commitment`. The contract-side
/// `CommitmentEntry` shape varies per governance type — only
/// `commitment` and `epoch` are present in every variant. The rest
/// are decoded `if present`:
///
/// | Field        | anarchy | 1v1 | tyranny | democracy | oligarchy |
/// |--------------|---------|-----|---------|-----------|-----------|
/// | `commitment` | ✅      | ✅  | ✅      | ✅        | ✅        |
/// | `epoch`      | ✅      | ✅  | ✅      | ✅        | ✅        |
/// | `timestamp`  | (varies)| ✅  | ✅      | ✅        | ✅        |
/// | `tier`       | (varies)| —   | ✅      | ✅        | ✅        |
/// | `active`     | —       | —   | —       | ✅        | ✅        |
public struct SEPCommitmentEntry: Codable, Equatable, Sendable {
    public let commitment: Data
    public let epoch: UInt64
    let timestamp: UInt64?
    let tier: UInt32?
    let active: Bool?

    public init(
        commitment: Data,
        epoch: UInt64,
        timestamp: UInt64? = nil,
        tier: UInt32? = nil,
        active: Bool? = nil
    ) {
        self.commitment = commitment
        self.epoch = epoch
        self.timestamp = timestamp
        self.tier = tier
        self.active = active
    }
}

/// Relayer's response to a contract-invocation POST. Mirrors
/// `RelayerResponse` in `onym-relayer/src/handler.rs` — top-level
/// camelCase with optional `transactionHash` and `message`.
public struct SEPSubmissionResponse: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let transactionHash: String?
    public let message: String?

    public init(accepted: Bool, transactionHash: String?, message: String?) {
        self.accepted = accepted
        self.transactionHash = transactionHash
        self.message = message
    }
}

public enum SEPError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse(statusCode: Int, body: String)
    case decodeFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidResponse(statusCode, body):
            return "HTTP \(statusCode): \(body)"
        case let .decodeFailure(message):
            return "Decode failure: \(message)"
        }
    }
}
