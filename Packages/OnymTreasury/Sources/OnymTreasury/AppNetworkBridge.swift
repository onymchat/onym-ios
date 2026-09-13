import OnymChain
import OnymStellar

public extension AppNetwork {
    /// The Stellar network the user's Settings toggle selects.
    ///
    /// `AppNetwork` lives in `OnymChain`, which knows about Soroban
    /// contracts and the relayer but nothing about classic Stellar; the
    /// bridge lives here rather than there so the chain package does not
    /// take a dependency on the treasury's codec.
    ///
    /// The same toggle governs both, deliberately. A device pinned to
    /// testnet for its group contracts creating a *mainnet* treasury
    /// would be spending real money from a screen that says "testnet"
    /// everywhere else.
    var stellarNetwork: StellarNetwork {
        switch self {
        case .testnet: .testnet
        case .mainnet: .publicNet
        }
    }
}
