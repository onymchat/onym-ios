import Foundation

/// Stellar network the contract is deployed on. `public` is Stellar's
/// own name for what most users call "mainnet" — kept for parity with
/// the Stellar passphrase strings.
enum ContractNetwork: String, Codable, CaseIterable, Hashable, Sendable {
    case testnet
    case `public`

    /// User-facing label.
    var displayName: String {
        switch self {
        case .testnet: return "Testnet"
        case .public: return "Mainnet"
        }
    }
}

/// Governance type — pinned to the five known SEP contract families.
/// The on-wire `type` string carries the wire name (`oneonone`, etc.);
/// the manifest decoder silently drops entries with unknown values so
/// a future governance type doesn't crash an older client.
enum GovernanceType: String, Codable, CaseIterable, Hashable, Sendable {
    case anarchy
    case democracy
    case oligarchy
    case oneonone
    case tyranny

    /// User-facing label.
    var displayName: String {
        switch self {
        case .anarchy: return "Anarchy"
        case .democracy: return "Democracy"
        case .oligarchy: return "Oligarchy"
        case .oneonone: return "One-on-one"
        case .tyranny: return "Tyranny"
        }
    }
}

/// One contract deployment — a (network, type, contract id) triple.
struct ContractEntry: Codable, Equatable, Hashable, Sendable {
    let network: ContractNetwork
    let type: GovernanceType
    let id: String
}

/// One release of `onymchat/onym-contracts` — a tag + publish date +
/// the set of contracts deployed in it.
struct ContractRelease: Codable, Equatable, Hashable, Sendable {
    let release: String       // e.g. "v0.0.2"
    let publishedAt: Date
    let contracts: [ContractEntry]
}

/// Wire shape of the `contracts-manifest.json` asset attached to the
/// latest release. `releases[]` is the union of all historical
/// releases — newest-first. Regenerated and re-attached on every new
/// release (CI step in the contracts repo).
struct ContractsManifest: Codable, Equatable, Sendable {
    let version: Int
    let releases: [ContractRelease]

    static let empty = ContractsManifest(version: 0, releases: [])
}
