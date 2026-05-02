import Foundation

/// Stateless interactor for the relayer picker. Owns the per-screen
/// state machine (current snapshot, custom-URL draft text, validation
/// state) and dispatches commands to the repository. The view reads
/// `state` and emits intents; the repository owns persistence.
@MainActor
@Observable
final class RelayerPickerFlow {
    /// Combined snapshot from the repository plus the custom-URL
    /// draft the user is currently typing. The draft is local-only
    /// until they tap Save — the repository never sees half-typed
    /// URLs.
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
                // If the user already had a known selection, prefill
                // the custom draft empty (don't disturb it if they're
                // mid-type).
                if case .custom(let url) = snapshot.selection, self.state.customDraft.isEmpty {
                    self.state.customDraft = url.absoluteString
                }
            }
        }
    }

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    // MARK: - Intents

    func tappedKnownRelayer(_ endpoint: RelayerEndpoint) {
        Task { await repository.select(endpoint) }
    }

    func customDraftChanged(_ text: String) {
        state.customDraft = text
        state.customDraftError = nil
    }

    func tappedSaveCustom() {
        let trimmed = state.customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.validate(trimmed) else {
            state.customDraftError = String(localized: "Enter a valid https:// URL")
            return
        }
        Task { await repository.selectCustom(url: url) }
    }

    func tappedClearSelection() {
        Task { await repository.clearSelection() }
    }

    /// Return the active URL (selected or nil) — used by chain
    /// interactor wiring once it lands.
    var activeURL: URL? {
        state.snapshot.selection?.url
    }

    // MARK: - Private

    /// Permissive URL validation: must parse, must have an http or
    /// https scheme, must have a host. Does not normalise; relayer
    /// will canonicalise if needed.
    static func validate(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}
