import Foundation
import Observation

/// `@Observable @MainActor` view-model for the Discovery Providers
/// Settings screen. Drains `DiscoveryRepository` snapshots into local
/// `state`; intents dispatch to the repository for source mutations.
///
/// Also owns the add-provider sub-flow (URL → fetched preview → TOFU
/// confirm), because its outcome mutates the same source list this
/// screen renders.
///
/// Lives in OnymDiscovery (not OnymSettings, which renders it) so its
/// state machine is unit-testable — OnymSettings has no test target.
@MainActor
@Observable
public final class DiscoverySettingsFlow {
    /// Where the add-provider sheet currently stands. The preview is
    /// fully verified but **nothing is pinned** until the user confirms
    /// the operator key fingerprint (`DiscoveryRepository.addSource`
    /// contract).
    public enum AddPhase {
        case idle
        case fetching
        case confirming(DiscoveryProviderPreview)
        case added
    }

    public private(set) var state: DiscoveryState = .empty

    // MARK: Add-provider sub-flow

    public var addDraft: String = ""
    public private(set) var addPhase: AddPhase = .idle
    public private(set) var addError: String?

    private let repository: DiscoveryRepository
    private var snapshotTask: Task<Void, Never>?
    /// The in-flight add-provider fetch, kept so `resetAdd` can cancel
    /// it (internal so tests can await its completion).
    @ObservationIgnored private(set) var addTask: Task<Void, Never>?
    /// The in-flight TOFU confirm. NOT cancelled by `resetAdd` — the
    /// user already confirmed the pin, so the persist + targeted
    /// refresh must run to completion; only the sheet-phase mutation
    /// is generation-guarded. Internal so tests can await it.
    @ObservationIgnored private(set) var confirmTask: Task<Void, Never>?
    /// Stale-completion guard for the add-provider fetch: bumped by
    /// every fetch AND every reset, so a completion from a superseded
    /// fetch (cancelled or not — `addSource` may not observe the
    /// cancellation) can never resurrect a dismissed sheet's phase.
    private var addGeneration = 0
    /// Double-tap guard for the Confirm button: set the moment the tap
    /// is accepted (NOT when `.added` lands), because the phase stays
    /// `.confirming` while the confirm task runs and a second tap in
    /// that window would run the whole pin + targeted-refresh pipeline
    /// again. Cleared when the confirm task finishes (`defer` in the
    /// task — the guard tracks the PIPELINE, not the sheet, so backing
    /// out of the preview and fetching a fresh URL must not leave
    /// Confirm a permanent no-op) and by `resetAdd` for the next sheet.
    @ObservationIgnored private var isConfirmInFlight = false

    public init(repository: DiscoveryRepository) {
        self.repository = repository
    }

    /// Begin draining repository snapshots. Idempotent — safe to call
    /// from `.task` on every appear.
    public func start() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.repository.snapshots {
                self.state = snapshot
            }
        }
    }

    public func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    // MARK: - Read helpers

    /// How many verified catalog entries a source currently contributes.
    public func entryCount(providerId: String) -> Int {
        state.aggregate.count { $0.source.providerId == providerId }
    }

    // MARK: - Intents

    /// Confirmed removal. Permanent by design: the providerId joins
    /// `removedDefaultProviderIds`, so no future seeding restores it —
    /// only an explicit re-add does.
    public func tappedRemove(providerId: String) {
        Task { await repository.removeSource(providerId: providerId) }
    }

    public func tappedRefresh() {
        Task { await repository.refresh() }
    }

    /// Awaitable variant for `.refreshable` (pull-to-refresh keeps its
    /// spinner until the pass completes).
    public func refresh() async {
        await repository.refresh()
    }

    /// "Confirm…" on an UNCONFIRMED source (the seeded default before
    /// its TOFU confirmation): reuse the add-provider path against the
    /// source's own manifest URL — fetch + verify, show the operator
    /// key fingerprint, and only pin on explicit confirm
    /// (`confirmAddSource` replaces the unpinned source in place).
    public func tappedConfirmSource(providerId: String) {
        guard let status = state.sources.first(where: { $0.id == providerId }) else { return }
        addDraft = status.source.manifestURL.absoluteString
        tappedFetchProvider()
    }

    /// "Fetch" in the add-provider sheet: validate the typed URL, fetch
    /// + verify the manifest, and move to the TOFU confirmation step.
    public func tappedFetchProvider() {
        let trimmed = addDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.validate(trimmed) else {
            addError = String(localized: "Enter a valid https:// URL")
            return
        }
        addError = nil
        addPhase = .fetching
        addGeneration += 1
        let generation = addGeneration
        addTask?.cancel()
        addTask = Task { [weak self] in
            do {
                let preview = try await self?.repository.addSource(manifestURL: url)
                guard let self, self.addGeneration == generation, let preview else { return }
                self.addPhase = .confirming(preview)
            } catch {
                guard let self, self.addGeneration == generation else { return }
                self.addError = DiscoveryUserMessage.message(for: error)
                self.addPhase = .idle
            }
        }
    }

    /// TOFU confirm: pin the previewed operator key, persist the
    /// source, and run a TARGETED refresh so its catalogs land in the
    /// aggregate. `refreshSource` (not `refresh()`) on purpose: a full
    /// pass already in flight captured its source list before this add
    /// and a coalescing `refresh()` would silently skip the new source.
    ///
    /// The sheet-phase mutation is guarded by `addGeneration` (same as
    /// the fetch path): dismissing the sheet mid-confirm must not set
    /// `.added` on a flow the user already walked away from. The pin
    /// itself still completes — the user explicitly confirmed it.
    public func tappedConfirmAdd() {
        guard case .confirming(let preview) = addPhase, !isConfirmInFlight else { return }
        isConfirmInFlight = true
        let generation = addGeneration
        confirmTask = Task { [weak self] in
            guard let self else { return }
            // The double-tap guard lasts exactly as long as the
            // pipeline: cleared on completion so a later Confirm (new
            // preview after Back → fresh fetch) is live again.
            defer { self.isConfirmInFlight = false }
            let source = await self.repository.confirmAddSource(preview)
            if self.addGeneration == generation {
                self.addPhase = .added
            }
            await self.repository.refreshSource(providerId: source.providerId)
        }
    }

    /// Back out of the TOFU confirmation without pinning anything.
    public func tappedCancelPreview() {
        if case .confirming = addPhase {
            // Backing out supersedes this preview the same way a
            // sheet dismissal does: bump the generation so an
            // in-flight confirm's completion can never surface
            // `.added` over whatever the user does next (a fresh
            // URL's fetch → confirm cycle included). The pin itself
            // still completes if a confirm was already accepted.
            addGeneration += 1
            addPhase = .idle
        }
    }

    /// Reset the add-provider sub-flow (sheet dismissed). Invalidates
    /// any in-flight fetch: the task is cancelled AND the generation
    /// bump guarantees its completion can't set `addPhase` afterwards,
    /// so a dismissed sheet never resurrects as `.confirming`.
    public func resetAdd() {
        addGeneration += 1
        addTask?.cancel()
        addTask = nil
        addDraft = ""
        addPhase = .idle
        addError = nil
        isConfirmInFlight = false
    }

    /// Discovery manifests are https-only (profile URI rules) — this
    /// is stricter than the relayer picker's http allowance on purpose.
    public static func validate(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}
