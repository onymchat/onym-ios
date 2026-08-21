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
    /// Where a pending row's wait ended, mapped from the row's id to
    /// the group that replaced it.
    ///
    /// Kept after the row itself is gone, because the row disappearing
    /// is exactly the moment a screen showing it needs to know where to
    /// go instead. Bounded by the number of chats this identity has —
    /// the same order as the chats list.
    public private(set) var materialized: [String: String] = [:]
    public var lastError: String?

    private let repository: PendingChatRepository
    private let verificationStore: PendingVerificationStore
    private let groupRepository: GroupRepository
    /// Seals + sends a `JoinRequestPayload` for the given capability —
    /// the same `JoinRequestSender` the deeplink path uses.
    ///
    /// The third argument is the rules text that was on screen when the
    /// person agreed, which is what their signature ends up covering.
    /// It travels from the screen rather than being read back off the
    /// capability, so a request can never claim agreement to words
    /// nobody was shown.
    private let submitJoin: @Sendable (IntroCapability, String, String?) async -> JoinRequestSender.Outcome
    /// The joiner's display label, read lazily at accept time so an
    /// identity rename is picked up without re-wiring.
    ///
    /// Asked of the identity repository, for the same reason
    /// `currentIdentityID` is: a link that launches the app sends its
    /// request before any tab's `.task` has populated the identities
    /// flow, and reading the UI's copy shipped the request with an empty
    /// name — the founder seeing an unnamed stranger asking to come in.
    private let displayLabel: @Sendable () async -> String
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
        submitJoin: @escaping @Sendable (IntroCapability, String, String?) async -> JoinRequestSender.Outcome,
        displayLabel: @escaping @Sendable () async -> String,
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
        groupWatchTask = Task { @MainActor [weak self] in
            for await groups in groups {
                // Derived from the snapshot itself rather than from
                // `rows`, which may not have been filled yet when the
                // first group emission lands — the same ordering
                // `consumeForMaterialized` reads through the store to
                // survive. A pending row's id *is*
                // `<group hex>:<owner>`, so the mapping needs nothing
                // else to be exact.
                if let self {
                    for group in groups {
                        let rowID = "\(group.id):\(group.ownerIdentityID.rawValue.uuidString)"
                        self.materialized[rowID] = group.id
                    }
                }
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

    /// What a tapped invite link (or scanned QR) resolves to.
    ///
    /// Note what is *not* here: sending. A link arrives through an
    /// exported entry point — any app on the device can open it, and so
    /// can a page in a browser — so the arrival is a request to show
    /// something, never permission to speak. Every case below is
    /// therefore a screen; the request goes out from
    /// `confirmJoin(_:label:)`, which only a person can reach.
    public enum JoinDestination: Equatable, Sendable {
        /// Already a member — the link was an old one, or a second tap.
        /// Carries the hex group id so the caller can just open the chat.
        case alreadyJoined(groupIDHex: String)
        /// This device has already asked. Nothing more to send, and
        /// nothing more to disclose: open the wait.
        case waiting(rowID: String)
        /// Show the confirmation screen.
        case confirm(JoinConfirmation)
        /// Nothing could be resolved, and the caller has to say so.
        case failed(reason: String)
    }

    /// Everything the confirmation screen shows, and everything
    /// `confirmJoin` needs to act on it.
    ///
    /// It exists so the screen can name *who* is about to learn *what*
    /// before anything leaves the device: the group, the person who
    /// invited (when one did), and the invite key the request would be
    /// sealed to.
    public struct JoinConfirmation: Identifiable, Equatable, Sendable {
        /// Where the confirmation came from — a link this device just
        /// received, or an offer already sitting in the list.
        public enum Origin: Equatable, Sendable {
            case link(IntroCapability)
            case offer(rowID: String)
        }

        public var id: String { rowID }
        /// The row this will create or act on — `<group hex>:<owner>`.
        public let rowID: String
        public let groupIDHex: String
        public let groupName: String?
        /// Empty for a link: nobody introduced themselves.
        public let inviterAlias: String
        public let invitationMessage: String?
        /// The invite key the request is sealed to, for display. Whoever
        /// holds its private half is who this discloses to, and that is
        /// worth showing rather than describing.
        public let introPublicKey: Data
        /// The group's rules, when it has any. Shown on the screen and
        /// signed by Send — the same string for both, because a
        /// signature over anything other than what was read is not an
        /// agreement.
        public let rules: String?
        /// Pre-filled into the name field: the identity's own alias, or
        /// the name a previous attempt on this row used.
        public let suggestedLabel: String
        let origin: Origin
    }

    /// Resolve a capability into the next screen. Records nothing, sends
    /// nothing — see `JoinDestination`.
    public func prepareJoin(capability: IntroCapability) async -> JoinDestination {
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
        let rowID = "\(groupIDHex):\(owner.rawValue.uuidString)"
        let existing = await repository.currentChats().first { $0.id == rowID }
        // Already asked, on this link or a pushed offer for the same
        // group: one tap, one request. The wait is the whole answer.
        if let existing, existing.status != .offered {
            return .waiting(rowID: rowID)
        }
        // `??` takes an autoclosure, which can't await — and the name
        // this row asked under, when it has one, is the one to offer
        // back.
        let suggested: String
        if let asked = existing?.joinerLabel {
            suggested = asked
        } else {
            suggested = await displayLabel()
        }
        // The link's own copy wins over a stored offer's. Both should
        // say the same thing, and when they don't, the rules the person
        // is about to read have to be the ones that came with the
        // invitation they actually opened.
        let rules = GroupRules.normalized(capability.rules ?? existing?.invitationMessage)
        return .confirm(
            JoinConfirmation(
                rowID: rowID,
                groupIDHex: groupIDHex,
                groupName: capability.groupName ?? existing?.groupName,
                inviterAlias: existing?.inviterAlias ?? "",
                invitationMessage: existing?.invitationMessage,
                introPublicKey: capability.introPublicKey,
                rules: rules,
                suggestedLabel: suggested,
                origin: .link(capability)
            )
        )
    }

    /// The same screen, reached from the Accept on a pushed offer.
    ///
    /// One path for both, so what a person is shown before their name
    /// and keys leave the device does not depend on which door the
    /// invitation came through.
    public func prepareAccept(rowID: String) async -> JoinConfirmation? {
        guard let chat = pending.first(where: { $0.id == rowID }), chat.status == .offered
        else { return nil }
        let suggested: String
        if let asked = chat.joinerLabel {
            suggested = asked
        } else {
            suggested = await displayLabel()
        }
        return JoinConfirmation(
            rowID: chat.id,
            groupIDHex: chat.groupIDHex,
            groupName: chat.groupName,
            inviterAlias: chat.inviterAlias,
            invitationMessage: chat.invitationMessage,
            introPublicKey: chat.introPublicKey,
            // A pushed invitation carries its rules on the stored offer
            // — there is no capability to read them from.
            //
            // Normalized here rather than trusted: a group whose rules
            // are whitespace has none, and passing `"   "` through
            // would draw an empty rules card, demand a tick for it, and
            // then send no signature at all, because the sender
            // normalizes before signing.
            rules: GroupRules.normalized(chat.invitationMessage),
            suggestedLabel: suggested,
            origin: .offer(rowID: chat.id)
        )
    }

    /// The one place a join request is sent, and the only one a person
    /// can reach: the Send on the confirmation screen.
    ///
    /// `label` is what they typed. It rides with this join and does not
    /// touch the identity — one identity can introduce itself
    /// differently to different rooms — and it is stored on the row so a
    /// later re-send says the same thing.
    @discardableResult
    public func confirmJoin(
        _ confirmation: JoinConfirmation,
        label: String
    ) async -> JoinDestination {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch confirmation.origin {
        case .offer(let rowID):
            guard let chat = pending.first(where: { $0.id == rowID }) else {
                return .failed(reason: String(localized: "Couldn\u{2019}t save this invite on your device."))
            }
            // The same `.offered` check `prepareAccept` made, re-made
            // here: an open screen can outlive the state it was opened
            // on, and a row that has already asked has nothing left to
            // send — the wait is the whole answer. `send`'s debounce
            // catches the double tap; this catches the row that moved
            // on underneath.
            guard chat.status == .offered else { return .waiting(rowID: rowID) }
            await repository.attachJoinerLabel(id: rowID, label: trimmed)
            send(chat, label: trimmed, rules: confirmation.rules)
            return .waiting(rowID: rowID)
        case .link(let capability):
            guard let owner = await currentIdentityID() else {
                return .failed(reason: String(localized: "Sign in first."))
            }
            let chat = PendingChat(
                groupID: capability.groupId,
                ownerIdentityID: owner,
                introPublicKey: capability.introPublicKey,
                groupName: capability.groupName,
                // Nobody introduced themselves over a link — the row
                // shows the group, not a person who never said their
                // name.
                inviterAlias: "",
                // The rules the screen showed, kept on the row: "Ask
                // again" has to re-sign the same text, and the row is
                // the only place it survives once the capability is
                // gone. The screen's copy, not the capability's, so the
                // two can't drift.
                invitationMessage: confirmation.rules,
                receivedAt: Date(),
                status: .offered,
                joinerLabel: trimmed
            )
            switch await repository.record(chat) {
            case .inserted:
                send(chat, label: trimmed, rules: confirmation.rules)
                return .waiting(rowID: chat.id)
            case .alreadyPresent:
                // A pushed offer for this group arrived first and is
                // still unanswered — this Send is the answer to it.
                await repository.attachJoinerLabel(id: chat.id, label: trimmed)
                let existing = await repository.currentChats().first { $0.id == chat.id }
                if let existing, existing.status == .offered {
                    // The stored offer's text may differ from the
                    // link's, and the screen resolved the link's ahead
                    // of it. So the row is brought up to what was
                    // actually read before anything is signed —
                    // otherwise this send, and every "Ask again" after
                    // it, would attest to words nobody saw.
                    let shown = PendingChat(
                        groupID: existing.groupID,
                        ownerIdentityID: existing.ownerIdentityID,
                        introPublicKey: existing.introPublicKey,
                        groupName: existing.groupName,
                        inviterAlias: existing.inviterAlias,
                        invitationMessage: confirmation.rules,
                        receivedAt: existing.receivedAt,
                        status: existing.status,
                        joinerLabel: trimmed
                    )
                    await repository.refreshOffer(shown)
                    send(shown, label: trimmed, rules: confirmation.rules)
                }
                return .waiting(rowID: chat.id)
            case .failed, .notRecorded:
                return .failed(reason: String(localized: "Couldn\u{2019}t save this invite on your device."))
            }
        }
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
            // Under the name this row already asked under — a re-send
            // that renamed the asker would arrive from a stranger.
            //
            // A row can have no label and still have asked: every row
            // written before the confirmation screen existed sent under
            // the identity's own name, and those are the rows most
            // likely to need this, having waited through an update. So
            // the fallback is that name, attached on the way out so the
            // one after this repeats it rather than re-deriving it from
            // an identity that may since have been renamed.
            if let label = chat.joinerLabel {
                send(chat, label: label, rules: GroupRules.normalized(chat.invitationMessage))
                return
            }
            let repository = self.repository
            let displayLabel = self.displayLabel
            Task { @MainActor [weak self] in
                let label = await displayLabel()
                await repository.attachJoinerLabel(id: id, label: label)
                self?.send(
                    chat,
                    label: label,
                    rules: GroupRules.normalized(chat.invitationMessage)
                )
            }
        case .offered, .chainSettling:
            break
        }
    }

    /// The one send path, shared by the confirmation screen's Send and
    /// by a re-send. Debounced on `sendingIDs` so a double tap ships one
    /// request.
    ///
    /// `label` is always supplied by a caller a person reached: there is
    /// no path from an inbound link or event to here.
    ///
    /// `rules` is passed rather than read off `chat`, because the two
    /// can disagree and only one of them is the agreement: the screen
    /// resolves a link's rules ahead of a stored offer's, so a row
    /// whose text differs would otherwise be signed instead of the
    /// words that were on screen. A re-send passes the row's own copy,
    /// which is the same text, kept for exactly that.
    private func send(_ chat: PendingChat, label: String, rules: String?) {
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
        let submitJoin = self.submitJoin
        let repository = self.repository
        Task { @MainActor [weak self] in
            let outcome = await submitJoin(capability, label, rules)
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
