#if DEBUG
import Foundation

/// App-side fakes used by `OnymIOSApp` when launched with the
/// `--ui-testing` argument. They live in production sources (not the
/// test target) because `OnymIOSApp.init` constructs them directly,
/// but the entire file is gated by `#if DEBUG` so none of it ships
/// to Release.
///
/// Distinct from the more-elaborate fakes under
/// `Tests/OnymIOSTests/Support/` (which power unit tests via
/// `@testable import OnymIOS` and have scripted/failing modes). Here
/// we just want deterministic fixtures the UI tests can assert
/// against — no scripting, no error injection.

// MARK: - Relayer

/// Returns a fixed pair of known relayers regardless of input. Tests
/// can assert on these names / URLs deterministically.
struct UITestKnownRelayersFetcher: KnownRelayersFetcher {
    static let testnet = RelayerEndpoint(
        name: "UITest Testnet Relayer",
        url: URL(string: "https://uitest-testnet-relayer.example")!,
        network: "testnet"
    )
    static let publicNet = RelayerEndpoint(
        name: "UITest Mainnet Relayer",
        url: URL(string: "https://uitest-mainnet-relayer.example")!,
        network: "public"
    )

    func fetchLatest() async throws -> [RelayerEndpoint] {
        [Self.testnet, Self.publicNet]
    }
}

/// In-memory `RelayerSelectionStore` so each UI test launch starts
/// with no persisted configuration (the auto-populate path then
/// hydrates from the `UITestKnownRelayersFetcher` above).
final class UITestRelayerSelectionStore: RelayerSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: RelayerConfiguration = .empty
    private var cachedList: [RelayerEndpoint] = []

    func loadConfiguration() -> RelayerConfiguration {
        lock.withLock { configuration }
    }

    func saveConfiguration(_ configuration: RelayerConfiguration) {
        lock.withLock { self.configuration = configuration }
    }

    func loadCachedKnownList() -> [RelayerEndpoint] {
        lock.withLock { cachedList }
    }

    func saveCachedKnownList(_ list: [RelayerEndpoint]) {
        lock.withLock { cachedList = list }
    }
}

// MARK: - Contracts

/// Returns a fixed two-release manifest. v0.0.2 is newer (default-to-
/// latest picks it) and includes all five governance types on testnet
/// only. v0.0.1 is older and has a subset. Mainnet stays empty so the
/// "No contracts yet" branch can be exercised.
struct UITestContractsManifestFetcher: ContractsManifestFetcher {
    func fetchLatest() async throws -> ContractsManifest {
        let v002 = ContractRelease(
            release: "v0.0.2",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_002),
            contracts: [
                ContractEntry(network: .testnet, type: .anarchy,   id: "CDWYYK"),
                ContractEntry(network: .testnet, type: .democracy, id: "CBEBQM"),
                ContractEntry(network: .testnet, type: .oligarchy, id: "CBHY24"),
                ContractEntry(network: .testnet, type: .oneonone,  id: "CAHXGZ"),
                ContractEntry(network: .testnet, type: .tyranny,   id: "CC6Y2F"),
            ]
        )
        let v001 = ContractRelease(
            release: "v0.0.1",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_001),
            contracts: [
                ContractEntry(network: .testnet, type: .anarchy,   id: "CDSIJT"),
                ContractEntry(network: .testnet, type: .democracy, id: "CBYHYJ"),
            ]
        )
        return ContractsManifest(version: 1, releases: [v002, v001])
    }
}

/// In-memory `AnchorSelectionStore` so each UI test launch starts
/// with no persisted selections.
final class UITestAnchorSelectionStore: AnchorSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var selections: [AnchorSelectionKey: String] = [:]
    private var manifest: ContractsManifest?

    func loadSelections() -> [AnchorSelectionKey: String] {
        lock.withLock { selections }
    }

    func saveSelections(_ selections: [AnchorSelectionKey: String]) {
        lock.withLock { self.selections = selections }
    }

    func loadCachedManifest() -> ContractsManifest? {
        lock.withLock { manifest }
    }

    func saveCachedManifest(_ manifest: ContractsManifest) {
        lock.withLock { self.manifest = manifest }
    }
}

#endif
