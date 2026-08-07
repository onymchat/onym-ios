import Foundation

/// User's selected Stellar network for new groups. Defaults to
/// `.testnet` because the v0.0.3 contracts only ship there today;
/// `.mainnet` is reachable via the Settings → Network toggle once
/// real contracts land on it.
public enum AppNetwork: String, Codable, CaseIterable, Sendable {
    case testnet
    case mainnet

    /// Bridges to `ContractNetwork` (used by `AnchorSelectionKey` for
    /// the contracts manifest). The wire spelling is `public` for
    /// mainnet — see `SEPNetwork`.
    public var contractNetwork: ContractNetwork {
        switch self {
        case .testnet: .testnet
        case .mainnet: .public
        }
    }

    public var sepNetwork: SEPNetwork {
        switch self {
        case .testnet: .testnet
        case .mainnet: .publicNet
        }
    }
}

/// Read-only seam over whichever store backs the user's preference.
/// `CreateGroupInteractor` depends on this rather than UserDefaults so
/// tests can swap it without touching `@AppStorage`.
public protocol NetworkPreferenceProviding: Sendable {
    func current() -> AppNetwork
}

/// Production impl — backed by `UserDefaults` under the same key the
/// Settings `Toggle` reads via `@AppStorage("onym.useMainnet")`.
public struct UserDefaultsNetworkPreference: NetworkPreferenceProviding, @unchecked Sendable {
    public static let storageKey = "onym.useMainnet"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func current() -> AppNetwork {
        defaults.bool(forKey: Self.storageKey) ? .mainnet : .testnet
    }
}

/// Test fake — returns whatever was passed in.
public struct StaticNetworkPreference: NetworkPreferenceProviding {
    let value: AppNetwork

    public init(value: AppNetwork) {
        self.value = value
    }

    public func current() -> AppNetwork { value }
}
