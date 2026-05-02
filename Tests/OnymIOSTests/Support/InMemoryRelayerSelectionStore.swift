import Foundation
@testable import OnymIOS

/// `RelayerSelectionStore` impl backed by in-memory state. Used by
/// repository tests that don't need to exercise the UserDefaults
/// plumbing — same role as `InMemoryAnchorSelectionStore`.
final class InMemoryRelayerSelectionStore: RelayerSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: RelayerConfiguration
    private var cachedList: [RelayerEndpoint]

    init(
        configuration: RelayerConfiguration = .empty,
        cachedList: [RelayerEndpoint] = []
    ) {
        self.configuration = configuration
        self.cachedList = cachedList
    }

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
