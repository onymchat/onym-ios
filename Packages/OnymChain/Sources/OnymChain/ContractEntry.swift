import Foundation

/// Stellar network the contract is deployed on. `public` is Stellar's
/// own name for what most users call "mainnet" — kept for parity with
/// the Stellar passphrase strings.
public enum ContractNetwork: String, Codable, CaseIterable, Hashable, Sendable {
    case testnet
    case `public`

    /// Localised label. Plain `String` so it composes into row text
    /// without ceremony; values are looked up against
    /// `Localizable.xcstrings` at access time.
    public var displayName: String {
        switch self {
        case .testnet: return String(localized: "Testnet")
        case .public: return String(localized: "Mainnet")
        }
    }
}

/// Governance type — pinned to the five known SEP contract families.
/// The on-wire `type` string carries the wire name (`oneonone`, etc.);
/// the manifest decoder silently drops entries with unknown values so
/// a future governance type doesn't crash an older client.
public enum GovernanceType: String, Codable, CaseIterable, Hashable, Sendable {
    case anarchy
    case democracy
    case oligarchy
    case oneonone
    case tyranny

    /// Localised label. See `ContractNetwork.displayName`.
    public var displayName: String {
        switch self {
        case .anarchy: return String(localized: "Anarchy")
        case .democracy: return String(localized: "Democracy")
        case .oligarchy: return String(localized: "Oligarchy")
        case .oneonone: return String(localized: "One-on-one")
        case .tyranny: return String(localized: "Founder")
        }
    }
}

/// One contract deployment — a (network, type, contract id) triple.
public struct ContractEntry: Codable, Equatable, Hashable, Sendable {
    public let network: ContractNetwork
    public let type: GovernanceType
    public let id: String

    public init(network: ContractNetwork, type: GovernanceType, id: String) {
        self.network = network
        self.type = type
        self.id = id
    }
}

/// One release of `onymchat/onym-contracts` — a tag + publish date +
/// the set of contracts deployed in it.
public struct ContractRelease: Codable, Equatable, Hashable, Sendable {
    public let release: String       // e.g. "v0.0.2"
    public let publishedAt: Date
    public let contracts: [ContractEntry]

    public init(release: String, publishedAt: Date, contracts: [ContractEntry]) {
        self.release = release
        self.publishedAt = publishedAt
        self.contracts = contracts
    }
}

/// Wire shape of the `contracts-manifest.json` asset attached to the
/// latest release. `releases[]` is the union of all historical
/// releases — newest-first. Regenerated and re-attached on every new
/// release (CI step in the contracts repo).
public struct ContractsManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let releases: [ContractRelease]

    static let empty = ContractsManifest(version: 0, releases: [])

    public init(version: Int, releases: [ContractRelease]) {
        self.version = version
        self.releases = releases
    }
}
