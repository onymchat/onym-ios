import Foundation
import Observation

/// `@Observable @MainActor` driver for the invitee-side "you've been
/// invited" surface — the push counterpart to `JoinFlow` (which handles
/// deeplink joins). Mirrors `ApproveRequestsFlow`'s shape: a shared
/// instance whose `pending` list backs both the Chats toolbar badge and
/// the modal list.
///
/// Accept is the *explicit* step the design requires: it turns a
/// `PendingInvite` (an offer) into a `JoinRequestPayload` shipped to the
/// admin's intro key. Nothing here anchors the roster — the admin still
/// has to explicitly approve the resulting request. The group appears
/// on accept only after that approval lands and materializes it, at
/// which point `start()`'s group watcher consumes the spent invite.
@MainActor
@Observable
final class PendingInvitesFlow {
    /// Pending invites for the current identity, newest first.
    var pending: [PendingInvite] = []
    /// Groups that were accepted but couldn't be verified at an exact
    /// epoch yet — awaiting (or unable to get) the current state from
    /// the admin. Surfaced so the user knows a join is in flight or
    /// stuck. Hidden from the chats list until verified.
    var verifying: [PendingGroupVerification] = []
    /// IDs whose accept call is in flight (drives the per-row spinner).
    var inFlightIDs: Set<String> = []
    /// IDs whose join request has been sent and is awaiting the admin's
    /// approval. Relabels the row and disables Accept so the user
    /// doesn't double-request.
    var requestedIDs: Set<String> = []
    var lastError: String?

    /// Total count for the toolbar badge — pending offers plus groups
    /// still verifying / stuck.
    var badgeCount: Int { pending.count + verifying.count }

    private let store: PendingInvitesStore
    private let verificationStore: PendingVerificationStore
    private let groupRepository: GroupRepository
    /// Mirrors `JoinFlow`'s injected `submitRequest` — seals + sends a
    /// `JoinRequestPayload` for the given capability. Returns the
    /// sender outcome so the flow can surface errors.
    private let submitJoin: @Sendable (IntroCapability, String) async -> JoinRequestSender.Outcome
    /// Resolves the joiner's display label at accept time (the active
    /// identity's alias). Read lazily so an identity rename is picked
    /// up without re-wiring.
    private let displayLabel: @MainActor () -> String
    /// Re-send a stuck verification's refresh request (Retry button).
    private let retryVerification: @Sendable (String) async -> Void

    private var streamingTask: Task<Void, Never>?
    private var verifyingTask: Task<Void, Never>?
    private var groupWatchTask: Task<Void, Never>?

    init(
        store: PendingInvitesStore,
        verificationStore: PendingVerificationStore,
        groupRepository: GroupRepository,
        submitJoin: @escaping @Sendable (IntroCapability, String) async -> JoinRequestSender.Outcome,
        displayLabel: @escaping @MainActor () -> String,
        retryVerification: @escaping @Sendable (String) async -> Void
    ) {
        self.store = store
        self.verificationStore = verificationStore
        self.groupRepository = groupRepository
        self.submitJoin = submitJoin
        self.displayLabel = displayLabel
        self.retryVerification = retryVerification
    }

    func isInFlight(_ id: String) -> Bool { inFlightIDs.contains(id) }
    func isRequested(_ id: String) -> Bool { requestedIDs.contains(id) }

    /// Mirror the store's snapshot into `pending` and watch groups so a
    /// spent invite is dropped once its group materializes. Idempotent.
    func start() async {
        guard streamingTask == nil else { return }
        let stream = store.snapshots
        streamingTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard let self else { break }
                self.pending = snapshot
                // Forget request/in-flight bookkeeping for invites that
                // are no longer present (consumed / identity switch).
                let live = Set(snapshot.map(\.id))
                self.requestedIDs.formIntersection(live)
                self.inFlightIDs.formIntersection(live)
            }
        }
        let vstream = verificationStore.snapshots
        verifyingTask = Task { @MainActor [weak self] in
            for await snapshot in vstream {
                guard let self else { break }
                self.verifying = snapshot
            }
        }
        let groups = groupRepository.snapshots
        let store = self.store
        groupWatchTask = Task {
            for await groups in groups {
                await store.consumeForMaterializedGroups(
                    Set(groups.map(\.groupIDData))
                )
            }
        }
    }

    func stop() {
        streamingTask?.cancel()
        streamingTask = nil
        verifyingTask?.cancel()
        verifyingTask = nil
        groupWatchTask?.cancel()
        groupWatchTask = nil
    }

    /// Retry a verification that got stuck because the admin was
    /// unreachable for the current-state refresh.
    func retry(_ groupIDHex: String) {
        let retryVerification = self.retryVerification
        Task { await retryVerification(groupIDHex) }
    }

    /// Explicit Accept: ship a join request to the offer's intro key.
    /// No-op while already in flight or already requested.
    func accept(_ id: String) {
        guard !inFlightIDs.contains(id), !requestedIDs.contains(id) else { return }
        guard let invite = pending.first(where: { $0.id == id }) else { return }
        let capability: IntroCapability
        do {
            capability = try IntroCapability(
                introPublicKey: invite.introPublicKey,
                groupId: invite.groupID,
                groupName: invite.groupName
            )
        } catch {
            lastError = "This invite is malformed and can't be accepted."
            return
        }
        inFlightIDs.insert(id)
        lastError = nil
        let label = displayLabel()
        let submitJoin = self.submitJoin
        Task { @MainActor [weak self] in
            let outcome = await submitJoin(capability, label)
            guard let self else { return }
            self.inFlightIDs.remove(id)
            switch outcome {
            case .sent:
                self.requestedIDs.insert(id)
            case .noIdentityLoaded:
                self.lastError = "Sign in first."
            case .transportFailed(let reason):
                self.lastError = "Couldn't send request: \(reason)"
            }
        }
    }

    /// Drop an invite the user doesn't want. Local-only — no NACK to
    /// the admin (their outstanding intro key just goes unused).
    func dismiss(_ id: String) {
        let store = self.store
        Task { await store.consume(id: id) }
    }

    func dismissError() { lastError = nil }
}
