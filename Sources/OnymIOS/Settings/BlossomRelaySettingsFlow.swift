import Foundation
import Observation

/// `@Observable @MainActor` view-model for the Blossom-servers Settings
/// screen. Drains `BlossomServersRepository` snapshots into local
/// `state.snapshot`; intents dispatch to the repository for
/// configuration mutations. Mirrors `NostrRelaySettingsFlow`.
///
/// Blossom servers speak HTTPS (`https://` / `http://` for local dev),
/// so validation + placeholder copy differ from the `wss://` Nostr
/// flow; there's no primary/strategy concept (uploads target the first
/// configured server).
@MainActor
@Observable
final class BlossomRelaySettingsFlow {
    /// Combined snapshot from the repository plus the custom-URL draft
    /// the user is currently typing. Draft is local-only until Add.
    struct State: Equatable {
        var snapshot: BlossomServersConfiguration
        var customDraft: String
        var customDraftError: String?
    }

    private(set) var state: State

    private let repository: BlossomServersRepository
    private var snapshotTask: Task<Void, Never>?

    init(repository: BlossomServersRepository) {
        self.repository = repository
        self.state = State(snapshot: .empty, customDraft: "", customDraftError: nil)
    }

    /// Begin draining repository snapshots. Idempotent.
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

    func customDraftChanged(_ text: String) {
        state.customDraft = text
        state.customDraftError = nil
    }

    /// Tap the Add button next to the custom-URL field. Validates
    /// `https://` / `http://` scheme + non-empty host.
    func tappedAddCustom() {
        let trimmed = state.customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.validate(trimmed) else {
            state.customDraftError = String(localized: "Enter a valid https:// URL")
            return
        }
        let endpoint = BlossomServerEndpoint.custom(url: url)
        state.customDraft = ""
        Task { await repository.addEndpoint(endpoint) }
    }

    /// Swipe-to-delete on a configured row.
    func tappedRemove(url: URL) {
        Task { await repository.removeEndpoint(url: url) }
    }

    /// Restore default — re-installs the Onym Official seed and clears
    /// the user-interaction flag so the seed sticks across relaunches.
    func tappedResetToDefault() {
        Task { await repository.resetToDefault() }
    }

    // MARK: - Private

    /// Permissive HTTP(S) URL validation: must parse, must have `https`
    /// or `http` scheme (the latter for local dev / loopback), must
    /// have a non-empty host.
    static func validate(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}
