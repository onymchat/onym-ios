import Foundation

/// Stateless interactor for the anchors drill-down. Drains
/// `ContractsRepository` snapshots into `state.snapshot`; intents
/// dispatch to the repository for selection mutations. The picker
/// view reads from `state` and calls the intent methods on tap;
/// navigation itself is owned by SwiftUI's `NavigationStack` (this
/// flow only knows about the data shape, not the navigation path).
@MainActor
@Observable
final class AnchorsPickerFlow {
    private(set) var state: ContractsState = .empty

    private let repository: ContractsRepository
    private var snapshotTask: Task<Void, Never>?

    init(repository: ContractsRepository) {
        self.repository = repository
    }

    /// Begin draining repository snapshots. Idempotent.
    func start() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.repository.snapshots {
                self.state = snapshot
            }
        }
    }

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    // MARK: - Read helpers (used by the picker views, all sync)

    /// Resolve `(network, type)` to its `AnchorBinding`. Pure read
    /// over `state` — safe to call from a SwiftUI cell.
    func binding(for key: AnchorSelectionKey) -> AnchorBinding? {
        state.binding(for: key)
    }

    /// Releases that have a contract for `key`, newest-first.
    func availableReleases(for key: AnchorSelectionKey) -> [ContractRelease] {
        state.availableReleases(for: key)
    }

    /// True when the user has explicitly picked a release for `key`
    /// (vs. falling back to default-to-latest). Drives the
    /// "(latest)" / "(selected)" subtitle on each row.
    func hasExplicitSelection(for key: AnchorSelectionKey) -> Bool {
        state.selections[key] != nil
    }

    /// True when at least one release has a contract on `network`.
    /// The Network row uses this to render Mainnet as disabled until
    /// contracts ship there.
    func hasAnyContracts(network: ContractNetwork) -> Bool {
        state.hasAnyContracts(network: network)
    }

    // MARK: - Intents

    func tappedVersion(key: AnchorSelectionKey, releaseTag: String) {
        Task { await repository.select(key: key, releaseTag: releaseTag) }
    }

    func tappedResetToDefault(key: AnchorSelectionKey) {
        Task { await repository.clearSelection(key: key) }
    }
}
