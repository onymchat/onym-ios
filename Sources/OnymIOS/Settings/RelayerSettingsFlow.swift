import Foundation

/// Stateless interactor backing the relayer Settings screen. Drains
/// `RelayerRepository` snapshots into local `state.snapshot`; intents
/// dispatch to the repository for configuration mutations. The view
/// reads from `state` and calls the intent methods on tap; navigation
/// itself is owned by SwiftUI.
@MainActor
@Observable
final class RelayerSettingsFlow {
    /// Combined snapshot from the repository plus the custom-URL
    /// draft the user is currently typing. The draft is local-only
    /// until they tap Add — the repository never sees half-typed URLs.
    struct State: Equatable {
        var snapshot: RelayerState
        var customDraft: String
        var customDraftError: String?
    }

    private(set) var state: State

    private let repository: RelayerRepository
    private var snapshotTask: Task<Void, Never>?

    init(repository: RelayerRepository) {
        self.repository = repository
        self.state = State(snapshot: .empty, customDraft: "", customDraftError: nil)
    }

    /// Begin draining repository snapshots. Idempotent — safe to call
    /// from `.task` on every appear.
    func start() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.repository.snapshots {
                self.state.snapshot = snapshot
            }
        }
    }

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    // MARK: - Intents

    /// User tapped a row in the published-list section to add it to
    /// the configured list.
    func tappedAddKnown(_ endpoint: RelayerEndpoint) {
        Task { await repository.addEndpoint(endpoint) }
    }

    func customDraftChanged(_ text: String) {
        state.customDraft = text
        state.customDraftError = nil
    }

    /// User tapped the Add button next to the custom-URL field.
    func tappedAddCustom() {
        let trimmed = state.customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.validate(trimmed) else {
            state.customDraftError = String(localized: "Enter a valid https:// URL")
            return
        }
        let endpoint = RelayerEndpoint.custom(url: url)
        state.customDraft = ""
        Task { await repository.addEndpoint(endpoint) }
    }

    /// Swipe-to-delete on a configured row.
    func tappedRemove(url: URL) {
        Task { await repository.removeEndpoint(url: url) }
    }

    /// Tap the star on a configured row to mark it primary.
    func tappedSetPrimary(url: URL) {
        Task { await repository.setPrimary(url: url) }
    }

    /// Strategy segmented control change.
    func tappedStrategy(_ strategy: RelayerStrategy) {
        Task { await repository.setStrategy(strategy) }
    }

    /// Retry button on a `.failed` fetch state. Kicks off another
    /// fetch; the repository sets `.fetching` immediately and the
    /// view re-renders accordingly.
    func tappedRetryFetch() {
        Task { try? await repository.refresh() }
    }

    // MARK: - Read helpers

    /// Configured endpoints that aren't already in the user's list —
    /// drives the "Add from published list" section. Hides published
    /// entries the user has already added so adding a duplicate
    /// doesn't ghost as a no-op.
    var unconfiguredKnownList: [RelayerEndpoint] {
        let configuredURLs = Set(state.snapshot.configuration.endpoints.map { $0.url })
        return state.snapshot.knownList.filter { !configuredURLs.contains($0.url) }
    }

    func isPrimary(_ endpoint: RelayerEndpoint) -> Bool {
        state.snapshot.configuration.primaryURL == endpoint.url
    }

    // MARK: - Private

    /// Permissive URL validation: must parse, must have an http or
    /// https scheme, must have a host. Same rules as the previous
    /// single-selection picker (PR #18).
    static func validate(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}
