import Foundation
@testable import OnymIOS

/// `AnchorSelectionStore` impl backed by plain in-memory state. Used
/// by repository tests that don't care about UserDefaults plumbing —
/// same role as `InMemoryRelayerSelectionStore` from PR #18.
final class InMemoryAnchorSelectionStore: AnchorSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var selections: [AnchorSelectionKey: String]
    private var manifest: ContractsManifest?

    init(
        selections: [AnchorSelectionKey: String] = [:],
        manifest: ContractsManifest? = nil
    ) {
        self.selections = selections
        self.manifest = manifest
    }

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
