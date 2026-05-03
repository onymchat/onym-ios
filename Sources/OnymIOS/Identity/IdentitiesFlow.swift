import Foundation
import Observation

/// `@Observable @MainActor` view-model for the multi-identity picker
/// + add/remove screens. Subscribes to `IdentityRepository`'s reactive
/// streams; SwiftUI views read fields directly and call intent
/// methods on tap.
///
/// PR-5 of the multi-identity stack — the underlying repository API
/// landed in PR-2, the chats filter in PR-3.
@MainActor
@Observable
final class IdentitiesFlow {
    /// Every persisted identity in display order. Re-sourced from
    /// `IdentityRepository.identitiesStream`.
    var identities: [IdentitySummary] = []
    /// The active identity, or nil when none exist (post-removal of
    /// the last identity, before `add` is called).
    var currentID: IdentityID?

    // MARK: - Add-flow state

    /// Bound to the AddIdentity sheet's name TextField.
    var pendingName: String = ""
    /// Bound to the AddIdentity sheet's "Restore from phrase" textbox.
    /// Empty → mint a fresh identity instead.
    var pendingMnemonic: String = ""
    /// Inline error shown on the AddIdentity sheet — surfaces invalid
    /// mnemonic or repository failures.
    var addError: String?

    // MARK: - Remove-flow state

    /// The identity currently being confirmed for removal, if any.
    /// `nil` hides the confirm sheet.
    var pendingRemoval: IdentitySummary?
    /// Bound to the confirm sheet's TextField. The Remove button is
    /// only enabled when this matches `pendingRemoval?.name` exactly
    /// (case-sensitive, trimmed).
    var pendingRemovalConfirmText: String = ""

    private let repository: IdentityRepository
    private var streamingTask: Task<Void, Never>?

    init(repository: IdentityRepository) {
        self.repository = repository
    }

    // MARK: - Lifecycle

    /// Start observing the repository's streams. Idempotent — a second
    /// `start` is a no-op so SwiftUI's `.task { await flow.start() }`
    /// can fire on every view appear without leaking subscribers.
    func start() async {
        guard streamingTask == nil else { return }
        let initialIdentities = await repository.currentIdentities()
        identities = initialIdentities
        currentID = await repository.currentSelectedID()

        streamingTask = Task { [weak self, repository] in
            // Two streams to fold; spawn one Task per stream so neither
            // blocks the other.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await identities in repository.identitiesStream {
                        await MainActor.run { self?.identities = identities }
                    }
                }
                group.addTask { [weak self] in
                    for await id in repository.currentIdentityID {
                        await MainActor.run { self?.currentID = id }
                    }
                }
            }
        }
    }

    /// Tear down the stream listeners. Call from `.onDisappear` /
    /// `deinit` if the flow's lifetime is bounded.
    func stop() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    // MARK: - Intents

    func select(_ id: IdentityID) {
        Task { try? await repository.select(id) }
    }

    /// Submit the AddIdentity sheet. On success the sheet is closed
    /// (`addError` cleared, `pendingName` reset); on failure the
    /// sheet stays open with the error inlined.
    func submitAdd() {
        let name = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let mnemonic = pendingMnemonic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil
        Task {
            do {
                _ = try await repository.add(name: name.isEmpty ? nil : name, mnemonic: mnemonic)
                pendingName = ""
                pendingMnemonic = ""
                addError = nil
            } catch IdentityError.invalidMnemonic {
                addError = "That doesn\u{2019}t look like a valid 12 or 24-word phrase."
            } catch {
                addError = String(describing: error)
            }
        }
    }

    /// Cancel the AddIdentity sheet. Clears the pending state.
    func cancelAdd() {
        pendingName = ""
        pendingMnemonic = ""
        addError = nil
    }

    // MARK: - Remove

    /// Show the confirm sheet for `summary`.
    func startRemoval(of summary: IdentitySummary) {
        pendingRemoval = summary
        pendingRemovalConfirmText = ""
    }

    /// True iff the user has typed the pending identity's name
    /// verbatim — gates the Remove button.
    var canConfirmRemoval: Bool {
        guard let pending = pendingRemoval else { return false }
        let typed = pendingRemovalConfirmText.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed == pending.name
    }

    /// Commit the pending removal. Closes the sheet on success.
    func confirmRemoval() {
        guard let pending = pendingRemoval, canConfirmRemoval else { return }
        let id = pending.id
        Task {
            try? await repository.remove(id)
            pendingRemoval = nil
            pendingRemovalConfirmText = ""
        }
    }

    /// Dismiss the confirm sheet without removing.
    func cancelRemoval() {
        pendingRemoval = nil
        pendingRemovalConfirmText = ""
    }

    // MARK: - View helpers

    /// Lowercase 12-char hex prefix of the BLS pubkey — what the
    /// picker rows show as the identity's "fingerprint".
    func blsPrefix(of summary: IdentitySummary) -> String {
        summary.blsPublicKey.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    /// Returns nil when self is empty after trimming; useful in
    /// `?? "fallback"` chains.
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
