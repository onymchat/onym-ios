import Foundation

/// One entry in the known-relayers list published at
/// `https://github.com/onymchat/onym-relayer/releases/latest/download/relayers.json`.
/// Pure value type — no behaviour, just the wire shape. Custom user-
/// added entries also use this type, with `network = "custom"`.
struct RelayerEndpoint: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Display name. For known entries, comes from the published list.
    /// For custom entries, defaults to the URL's host.
    let name: String
    /// Base URL of the relayer (no trailing slash).
    let url: URL
    /// `"testnet"` / `"public"` (Stellar mainnet) / `"custom"`. Drives
    /// the badge in the picker so a user doesn't accidentally treat a
    /// mainnet relayer as testnet (or vice versa).
    let network: String

    /// Stable id for SwiftUI list diffing — URL is the natural unique key.
    var id: URL { url }

    /// Sentinel for the `network` field of user-typed entries.
    static let customNetwork = "custom"

    /// Convenience for synthesising an endpoint from a custom URL the
    /// user typed. Name defaults to the URL's host so the row is
    /// recognisable even before the user gives it a friendlier label.
    static func custom(url: URL) -> RelayerEndpoint {
        RelayerEndpoint(
            name: url.host() ?? url.absoluteString,
            url: url,
            network: customNetwork
        )
    }
}

/// Top-level shape of the JSON asset attached to the latest release of
/// onym-relayer. The `version` field is for forward-compat: when we
/// change the wire shape we bump it and the parser can route on it.
struct KnownRelayersDocument: Codable, Equatable, Sendable {
    let version: Int
    let relayers: [RelayerEndpoint]
}

/// How the relayer URL is resolved per request. The user picks this in
/// Settings; chain interactors call `RelayerConfiguration.selectURL`
/// each time they need to POST.
enum RelayerStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    /// Always use the primary endpoint. If no primary is set,
    /// `selectURL` falls back to the first endpoint so a user with a
    /// single configured relayer doesn't have to also "promote" it.
    case primary
    /// Pick uniformly at random per request. Spreads load across all
    /// configured endpoints; useful when running redundant relayers.
    case random

    /// Localised label. Plain `String` so it composes into row text
    /// without ceremony; values are looked up against
    /// `Localizable.xcstrings` at access time.
    var displayName: String {
        switch self {
        case .primary: return String(localized: "Primary")
        case .random: return String(localized: "Random")
        }
    }
}

/// Full per-user configuration: the list of configured endpoints, an
/// optional primary marker, and the resolution strategy.
///
/// The list contains both endpoints adopted from the published list
/// (where `network` is `"testnet"` / `"public"`) and custom user-added
/// entries (where `network` is `"custom"`). Dedup by URL is enforced
/// at the repository layer.
struct RelayerConfiguration: Codable, Equatable, Hashable, Sendable {
    let endpoints: [RelayerEndpoint]
    /// URL of the primary endpoint. Nil = no explicit primary; with
    /// strategy `.primary`, `selectURL` falls back to `endpoints.first`.
    let primaryURL: URL?
    let strategy: RelayerStrategy
    /// `false` only on cold install before the first `RelayerRepository.refresh()`
    /// completes. The auto-populate path keys on this — the moment the
    /// known-relayers list arrives from GitHub, every published entry is
    /// added to `endpoints` and this flips to `true`. Any subsequent
    /// mutator (add / remove / setPrimary / setStrategy) also flips it
    /// to `true` so a user who explicitly clears the list isn't fought
    /// by another auto-populate on the next refresh.
    let hasUserInteracted: Bool

    static let empty = RelayerConfiguration(
        endpoints: [],
        primaryURL: nil,
        strategy: .random,
        hasUserInteracted: false
    )

    init(
        endpoints: [RelayerEndpoint],
        primaryURL: URL?,
        strategy: RelayerStrategy,
        hasUserInteracted: Bool = true
    ) {
        self.endpoints = endpoints
        self.primaryURL = primaryURL
        self.strategy = strategy
        self.hasUserInteracted = hasUserInteracted
    }

    /// Backward-compat: PR #20 saves don't carry `hasUserInteracted`.
    /// Treat absence as "yes, the user already interacted" so we don't
    /// re-auto-populate over a configuration they already touched.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoints = try c.decode([RelayerEndpoint].self, forKey: .endpoints)
        primaryURL = try c.decodeIfPresent(URL.self, forKey: .primaryURL)
        strategy = try c.decode(RelayerStrategy.self, forKey: .strategy)
        hasUserInteracted = try c.decodeIfPresent(Bool.self, forKey: .hasUserInteracted) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case endpoints, primaryURL, strategy, hasUserInteracted
    }

    /// Resolve the URL chain interactors should POST to. Pure — no
    /// side effects, no I/O, deterministic given the RNG. Returns
    /// `nil` when there are no endpoints to choose from.
    ///
    /// Strategy semantics:
    /// - `.primary`: return the endpoint whose URL matches
    ///   `primaryURL`. If `primaryURL` is nil OR doesn't match any
    ///   currently-configured endpoint, fall back to `endpoints.first`.
    /// - `.random`: return one of the endpoints uniformly at random.
    func selectURL<R: RandomNumberGenerator>(using rng: inout R) -> URL? {
        guard !endpoints.isEmpty else { return nil }
        switch strategy {
        case .primary:
            if let primaryURL, endpoints.contains(where: { $0.url == primaryURL }) {
                return primaryURL
            }
            return endpoints.first?.url
        case .random:
            return endpoints.randomElement(using: &rng)?.url
        }
    }

    /// Convenience for callers that don't need a deterministic RNG.
    /// Production chain interactors use this; tests inject a seeded
    /// RNG via the generic overload.
    func selectURL() -> URL? {
        var rng = SystemRandomNumberGenerator()
        return selectURL(using: &rng)
    }
}
