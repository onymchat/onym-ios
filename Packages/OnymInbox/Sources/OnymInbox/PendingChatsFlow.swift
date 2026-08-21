import Foundation
import Observation
import OnymIdentity
import OnymGroup

/// `@Observable @MainActor` driver for the chats a person is waiting to
/// be let into. It replaces the Invitations sheet: there is no separate
/// surface any more, so this feeds rows straight into the chats list and
/// the pending thread behind them.
///
/// It merges three sources, because the wait has three owners:
///
///   - `PendingChatRepository` — the offer, and whether we have asked yet;
///   - `PendingVerificationStore` — a group that was approved but can't
///     be verified against chain state yet (`GroupStateVerifier` owns
///     that state machine; nothing here duplicates it);
///   - `GroupRepository` — the end of the wait. When the group lands,
///     the pending row is consumed and the real chat takes its place,
///     opening on the "You joined X" notice the dispatcher already mints.
///
/// A verification with no pending row of its own still gets a row here.
/// That case is a stale invitation replayed by a relay onto a device that
/// never asked in this install, and it is the one the old sheet existed
/// to show: without a row it would be a group stuck forever, hidden from
/// the list by design and now with no screen left to surface it.
@MainActor
@Observable
public final class PendingChatsFlow {
    /// What the row is waiting on. Prose lives in the view — this is
    /// the same "structured data, not prose" rule `ChatSystemEvent`
    /// follows, so re-wording the copy touches one file.
    public enum State: Equatable, Sendable {
        /// A pushed offer nobody has answered. Accept sends the request.
        case offered
        /// Asked, and waiting on the founder — or on the verification
        /// round-trip that follows their approval. One state, because
        /// they are one wait to the person doing the waiting.
        case waiting
        /// The group's anchoring transaction hasn't settled yet. Not
        /// stuck, early: it clears itself, so no Retry.
        case chainSettling
        /// The founder couldn't be reached for the current-state reply.
        case founderUnreachable
        /// This device couldn't read the chain.
        case chainUnreachable
        /// This device has no relayer or contract binding yet — usually
        /// a cold-launch race rather than a wrong setting.
        case chainNotConfigured
        /// The join request itself couldn't be sent.
        case sendFailed(PendingChat.SendFailure)

        /// Whether this state has an action behind it — the Retry (or
        /// "Ask again") the pending thread offers.
        ///
        /// `.waiting` is included, and that is the point: a request that
        /// was sent and never answered had no way out at all. The link
        /// may have been revoked, or the request may have died in a
        /// relay, and re-tapping the link is a deliberate no-op for a
        /// row that already asked. Asking again is cheap and cannot
        /// spam: `JoinRequestApprover` collapses repeats by
        /// (joiner, group), and a decline stays declined.
        ///
        /// `chainSettling` is excluded on purpose: offering an action
        /// for something that resolves itself implies the user is
        /// holding it up. `.offered` is excluded because its action is
        /// Accept, not a retry.
        public var isRetryable: Bool {
            switch self {
            case .founderUnreachable, .chainUnreachable, .chainNotConfigured,
                 .sendFailed, .waiting:
                true
            case .offered, .chainSettling:
                false
            }
        }
    }

    /// One row in the chats list, and the whole content of the pending
    /// thread behind it.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let groupIDHex: String
        /// `nil` when the invite carried no name — the view supplies the
        /// placeholder, so history isn't frozen into one language.
        public let name: String?
        public let inviterAlias: String
        public let invitationMessage: String?
        public let receivedAt: Date
        public var state: State
        /// True while this row's Accept is in flight.
        public var isSending: Bool
        /// Whether the user can swipe this row away. False for a row
        /// synthesised from a verification alone: there is no stored
        /// offer under it to drop, and the group is still on its way, so
        /// a swipe that silently did nothing would be worse than no
        /// swipe at all.
        public var isDismissable: Bool
    }

    /// Pending rows for the current identity, newest first.
    public private(set) var rows: [Row] = []
    public var lastError: String?

    private let repository: PendingChatRepository
    private let verificationStore: PendingVerificationStore
    private let groupRepository: GroupRepository
    /// Seals + sends a `JoinRequestPayload` for the given capability —
    /// the same `JoinRequestSender` the deeplink path uses.
    private let submitJoin: @Sendable (IntroCapability, String) async -> JoinRequestSender.Outcome
    /// The joiner's display label, read lazily at accept time so an
    /// identity rename is picked up without re-wiring.
    private let displayLabel: @MainActor () -> String
    /// Re-drive a stuck verification (`GroupStateVerifier.retry`).
    private let retryVerification: @Sendable (String) async -> Void
    /// The identity a link tapped right now would join as.
    ///
    /// Asked of the identity repository rather than of the identities
    /// *flow*: a cold-start deeplink is handled before any tab's `.task`
    /// has populated the flow, so reading the UI's copy answered "no
    /// identity" for the one case that matters most — the link that
    /// launched the app.
    private let currentIdentityID: @Sendable () async -> IdentityID?

    private var pending: [PendingChat] = []
    private var verifying: [PendingGroupVerification] = []
    private var sendingIDs: Set<String> = []

    private var pendingTask: Task<Void, Never>?
    private var verifyingTask: Task<Void, Never>?
    private var groupWatchTask: Task<Void, Never>?

    public init(
        repository: PendingChatRepository,
        verificationStore: PendingVerificationStore,
        groupRepository: GroupRepository,
        submitJoin: @escaping @Sendable (IntroCapability, String) async -> JoinRequestSender.Outcome,
        displayLabel: @escaping @MainActor () -> String,
        retryVerification: @escaping @Sendable (String) async -> Void,
        currentIdentityID: @escaping @Sendable () async -> IdentityID?
    ) {
        self.repository = repository
        self.verificationStore = verificationStore
        self.groupRepository = groupRepository
        self.submitJoin = submitJoin
        self.displayLabel = displayLabel
        self.retryVerification = retryVerification
        self.currentIdentityID = currentIdentityID
    }

    /// Drain all three streams. Idempotent.
    public func start() async {
        guard pendingTask == nil else { return }
        let pendingStream = repository.snapshots
        pendingTask = Task { @MainActor [weak self] in
            for await snapshot in pendingStream {
                guard let self else { break }
                self.pending = snapshot
                self.sendingIDs.formIntersection(Set(snapshot.map(\.id)))
                self.rebuild()
            }
        }
        let verificationStream = verificationStore.snapshots
        verifyingTask = Task { @MainActor [weak self] in
            for await snapshot in verificationStream {
                guard let self else { break }
                self.verifying = snapshot
                self.rebuild()
            }
        }
        let groups = groupRepository.snapshots
        let repository = self.repository
        groupWatchTask = Task {
            for await groups in groups {
                await repository.consumeForMaterialized(
                    groups.map { (groupIDHex: $0.id, owner: $0.ownerIdentityID) }
                )
            }
        }
    }

    public func stop() {
        pendingTask?.cancel()
        pendingTask = nil
        verifyingTask?.cancel()
        verifyingTask = nil
        groupWatchTask?.cancel()
        groupWatchTask = nil
    }

    public func row(id: String) -> Row? { rows.first { $0.id == id } }

    /// The group a pending row turned into, once it has. `nil` while the
    /// wait is still on.
    public func materializedGroupID(for rowID: String) -> String? {
        materialized[rowID]
    }

    /// Where a tapped invite link (or scanned QR) leaves the user.
    public enum JoinOutcome: Equatable, Sendable {
        /// Already a member — the link was an old one, or a second tap.
        /// Carries the hex group id so the caller can just open the chat.
        case alreadyJoined(groupIDHex: String)
        /// A pending row exists and the request is on its way. Carries
        /// the row id to open.
        case waiting(rowID: String)
        /// Nothing could be recorded, so there is nothing to show and
        /// nothing to come back to. The caller has to say so out loud.
        case failed(reason: String)
    }

    /// Take a capability from a tapped link or a scanned QR and turn it
    /// into a chat that is on its way.
    ///
    /// This is what replaced the join sheet. The sheet asked for a
    /// display name and a Send tap before anything happened, and held
    /// the entire wait in memory behind a modal the user was told to
    /// keep open. Tapping the link *is* the intent, so the request goes
    /// out with the active identity's name and the wait becomes a row —
    /// which survives a force-quit, unlike the sheet.
    ///
    /// Re-tapping a link the user already acted on is deliberately not a
    /// second request: an existing row is returned as-is, and a Retry
    /// inside it is the way to send again.
    public func join(capability: IntroCapability) async -> JoinOutcome {
        guard let owner = await currentIdentityID() else {
            return .failed(reason: String(localized: "Sign in first."))
        }
        let groupIDHex = capability.groupId.map { String(format: "%02x", $0) }.joined()
        // Already in? Then the link is stale or double-tapped, and the
        // honest answer is the chat itself rather than a second wait.
        let groups = await groupRepository.currentGroups()
        if groups.contains(where: { $0.id == groupIDHex && $0.ownerIdentityID == owner }) {
            return .alreadyJoined(groupIDHex: groupIDHex)
        }
        let chat = PendingChat(
            groupID: capability.groupId,
            ownerIdentityID: owner,
            introPublicKey: capability.introPublicKey,
            groupName: capability.groupName,
            // Nobody introduced themselves over a link — the row shows
            // the group, not a person who never said their name.
            inviterAlias: "",
            invitationMessage: nil,
            receivedAt: Date(),
            status: .offered
        )
        switch await repository.record(chat) {
        case .inserted:
            send(chat)
            return .waiting(rowID: chat.id)
        case .alreadyPresent:
            return .waiting(rowID: chat.id)
        case .failed:
            return .failed(reason: String(localized: "Couldn\u{2019}t save this invite on your device."))
        }
    }

    /// Explicit Accept on a pushed offer: ship a join request to the
    /// offer's intro key. No-op once something is in flight, or once the
    /// row has moved past `.offered`.
    public func accept(_ id: String) {
        guard let chat = pending.first(where: { $0.id == id }), chat.status == .offered else {
            return
        }
        send(chat)
    }

    /// Act on whatever this row is stuck on: re-drive a stalled
    /// verification, or ask again — a request that never left, or one
    /// that left and was never answered.
    ///
    /// Which of the two depends on who is being waited on. Past the
    /// founder's approval the wait belongs to the verifier, and asking
    /// them again would achieve nothing; before it, the founder is the
    /// only one who can move it.
    public func retry(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        let hasVerification = verifying.contains { $0.groupIDHex == row.groupIDHex }
        switch row.state {
        case .founderUnreachable, .chainUnreachable, .chainNotConfigured:
            let retryVerification = self.retryVerification
            let hex = row.groupIDHex
            Task { await retryVerification(hex) }
        case .sendFailed, .waiting:
            if hasVerification {
                let retryVerification = self.retryVerification
                let hex = row.groupIDHex
                Task { await retryVerification(hex) }
                return
            }
            guard let chat = pending.first(where: { $0.id == id }) else { return }
            send(chat)
        case .offered, .chainSettling:
            break
        }
    }

    /// The one send path, shared by Accept and by Retry-after-failure.
    /// Debounced on `sendingIDs` so a double tap ships one request.
    private func send(_ chat: PendingChat) {
        let id = chat.id
        guard !sendingIDs.contains(id) else { return }
        let capability: IntroCapability
        do {
            capability = try IntroCapability(
                introPublicKey: chat.introPublicKey,
                groupId: chat.groupID,
                groupName: chat.groupName
            )
        } catch {
            lastError = String(localized: "This invite is malformed and can't be accepted.")
            return
        }
        sendingIDs.insert(id)
        lastError = nil
        rebuild()
        let label = displayLabel()
        let submitJoin = self.submitJoin
        let repository = self.repository
        Task { @MainActor [weak self] in
            let outcome = await submitJoin(capability, label)
            switch outcome {
            case .sent:
                await repository.markRequested(id: id)
            case .noIdentityLoaded:
                await repository.markFailed(id: id, failure: .noIdentity)
            case .transportFailed:
                // The transport's own wording doesn't survive a
                // translation or a re-read six months later, and it
                // tells the reader nothing they can act on. The code
                // carries what matters: it didn't go out.
                await repository.markFailed(id: id, failure: .transport)
            }
            guard let self else { return }
            self.sendingIDs.remove(id)
            self.rebuild()
        }
    }

    /// Drop a row the user swiped away.
    public func dismiss(_ id: String) {
        let repository = self.repository
        Task { await repository.remove(id: id) }
    }

    public func dismissError() { lastError = nil }

    // MARK: - Private

    /// Fold the three sources into `rows`. Verification status wins over
    /// the stored status when both describe the same group: by then the
    /// founder has approved and what the person is waiting on has moved
    /// on from them.
    ///
    /// Except over an offer nobody has answered. A verification says
    /// something about a join that was asked for, and an `.offered` row
    /// has asked for nothing — letting it win there took away the Accept
    /// button and left the person with no way to say yes.
    private func rebuild() {
        let verificationByHex = Dictionary(
            verifying.map { ($0.groupIDHex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var built: [Row] = pending.map { chat in
            Row(
                id: chat.id,
                groupIDHex: chat.groupIDHex,
                name: chat.groupName,
                inviterAlias: chat.inviterAlias,
                invitationMessage: chat.invitationMessage,
                receivedAt: chat.receivedAt,
                state: chat.status == .offered
                    ? .offered
                    : verificationByHex[chat.groupIDHex].map(Self.state(for:))
                        ?? Self.state(for: chat.status),
                isSending: sendingIDs.contains(chat.id),
                isDismissable: true
            )
        }
        // Verifications with no pending row of their own — see the type
        // comment. Keyed by hex, since there is no offer to key on.
        let covered = Set(built.map(\.groupIDHex))
        for entry in verifying where !covered.contains(entry.groupIDHex) {
            built.append(Row(
                id: entry.groupIDHex,
                groupIDHex: entry.groupIDHex,
                name: entry.groupName.isEmpty ? nil : entry.groupName,
                inviterAlias: "",
                invitationMessage: nil,
                receivedAt: entry.receivedAt,
                state: Self.state(for: entry),
                isSending: false,
                isDismissable: false
            ))
        }
        built.sort { $0.receivedAt > $1.receivedAt }
        rows = built
    }

    private static func state(for status: PendingChat.Status) -> State {
        switch status {
        case .offered:               .offered
        case .requested:             .waiting
        case .failed(let failure):   .sendFailed(failure)
        }
    }

    private static func state(for entry: PendingGroupVerification) -> State {
        switch entry.status {
        case .verifying:           .waiting
        case .chainSettling:       .chainSettling
        case .unreachable:         .founderUnreachable
        case .chainUnreachable:    .chainUnreachable
        case .chainNotConfigured:  .chainNotConfigured
        }
    }
}
