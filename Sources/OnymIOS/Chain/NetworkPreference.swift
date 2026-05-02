import Foundation

/// User's selected Stellar network for new groups. Defaults to
/// `.testnet` because the v0.0.3 contracts only ship there today;
/// `.mainnet` is reachable via the Settings → Network toggle once
/// real contracts land on it.
enum AppNetwork: String, Codable, CaseIterable, Sendable {
    case testnet
    case mainnet

    /// Bridges to `ContractNetwork` (used by `AnchorSelectionKey` for
    /// the contracts manifest). The wire spelling is `public` for
    /// mainnet — see `SEPNetwork`.
    var contractNetwork: ContractNetwork {
        switch self {
        case .testnet: .testnet
        case .mainnet: .public
        }
    }

    var sepNetwork: SEPNetwork {
        switch self {
        case .testnet: .testnet
        case .mainnet: .publicNet
        }
    }
}

/// Read-only seam over whichever store backs the user's preference.
/// `CreateGroupInteractor` depends on this rather than UserDefaults so
/// tests can swap it without touching `@AppStorage`.
protocol NetworkPreferenceProviding: Sendable {
    func current() -> AppNetwork
}

/// Production impl — backed by `UserDefaults` under the same key the
/// Settings `Toggle` reads via `@AppStorage("onym.useMainnet")`.
struct UserDefaultsNetworkPreference: NetworkPreferenceProviding, @unchecked Sendable {
    static let storageKey = "onym.useMainnet"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func current() -> AppNetwork {
        defaults.bool(forKey: Self.storageKey) ? .mainnet : .testnet
    }
}

/// Test fake — returns whatever was passed in.
struct StaticNetworkPreference: NetworkPreferenceProviding {
    let value: AppNetwork
    func current() -> AppNetwork { value }
}
