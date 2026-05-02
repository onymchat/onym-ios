import Foundation

/// One entry in the known-relayers list published at
/// `https://github.com/onymchat/onym-relayer/releases/latest/download/relayers.json`.
/// Pure value type — no behaviour, just the wire shape.
struct RelayerEndpoint: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Display name shown in the picker.
    let name: String
    /// Base URL of the relayer (no trailing slash).
    let url: URL
    /// `"testnet"` / `"public"` (Stellar mainnet) / freeform string. Drives
    /// the badge in the picker so a user doesn't accidentally pick mainnet
    /// when they meant testnet.
    let network: String

    /// Stable id for SwiftUI list diffing — URL is the natural unique key.
    var id: URL { url }
}

/// Top-level shape of the JSON asset attached to the latest release of
/// onym-relayer. The `version` field is for forward-compat: when we
/// change the wire shape we bump it and the parser can route on it.
struct KnownRelayersDocument: Codable, Equatable, Sendable {
    let version: Int
    let relayers: [RelayerEndpoint]
}

/// Persisted user choice. `.known(endpoint)` means the user picked one
/// of the entries from the published list; `.custom(url)` means they
/// typed in their own (e.g. a localhost relayer for development, or
/// a private deployment not in the public list).
enum RelayerSelection: Codable, Equatable, Hashable, Sendable {
    case known(RelayerEndpoint)
    case custom(URL)

    /// The URL chain interactors actually POST to, regardless of source.
    var url: URL {
        switch self {
        case .known(let endpoint): return endpoint.url
        case .custom(let url): return url
        }
    }
}
