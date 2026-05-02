import Foundation
@testable import OnymIOS

/// `RelayerSelectionStore` impl backed by a plain dictionary. Used by
/// any test that needs a `RelayerRepository` but doesn't care about
/// the UserDefaults plumbing — same role as `InMemoryInvitationStore`
/// from PR #16.
final class InMemoryRelayerSelectionStore: RelayerSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var selection: RelayerSelection?
    private var cachedList: [RelayerEndpoint] = []

    init(selection: RelayerSelection? = nil, cachedList: [RelayerEndpoint] = []) {
        self.selection = selection
        self.cachedList = cachedList
    }

    func loadSelection() -> RelayerSelection? {
        lock.withLock { selection }
    }

    func saveSelection(_ selection: RelayerSelection?) {
        lock.withLock { self.selection = selection }
    }

    func loadCachedKnownList() -> [RelayerEndpoint] {
        lock.withLock { cachedList }
    }

    func saveCachedKnownList(_ list: [RelayerEndpoint]) {
        lock.withLock { cachedList = list }
    }
}
