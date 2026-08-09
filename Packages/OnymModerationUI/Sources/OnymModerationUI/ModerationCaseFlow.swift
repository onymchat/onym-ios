import Foundation
import OnymModeration

/// Accused-side case screen state: authenticated status (with the
/// persisted snapshot as the offline fallback), response filing, and
/// appeal / new-holder filing. All gating here is ADVISORY — the
/// Authority is the arbiter (the reference accepts late responses and
/// answers 410 itself for a closed appeal window); this flow only
/// shapes affordances and never hard-blocks a submission the server
/// might still accept.
@MainActor
@Observable
public final class ModerationCaseFlow {
    public struct State: Equatable {
        public var status: CaseStatus?
        /// Non-nil while `status` is the persisted snapshot rather than
        /// a fresh fetch — the UI labels it as of this instant.
        public var snapshotFetchedAt: Date?
        public var isLoading = false
        public var isSubmittingResponse = false
        public var isSubmittingAppeal = false
        public var responseReceipt: CaseResponseReceipt?
        public var appealReceipt: AppealReceipt?
        public var statusErrorMessage: String?
        public var responseErrorMessage: String?
        public var appealErrorMessage: String?
    }

    public private(set) var state = State()
    public let caseId: String
    public let mandateRef: String
    /// True when opened from the ban surface: the appeal and
    /// new-holder affordances show even before (or without) a status
    /// fetch, because the caller already holds a ban verdict.
    public let banContext: Bool

    private let repository: ModerationRepository
    private let now: () -> Date

    public init(
        caseId: String,
        mandateRef: String,
        repository: ModerationRepository,
        banContext: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.caseId = caseId
        self.mandateRef = mandateRef
        self.repository = repository
        self.banContext = banContext
        self.now = now
    }

    public func start() async {
        if let stored = await repository.storedCaseStatus(caseId: caseId) {
            state.status = stored.status
            state.snapshotFetchedAt = stored.fetchedAt
        }
        await refresh()
    }

    public func refresh() async {
        guard !state.isLoading else { return }
        state.isLoading = true
        state.statusErrorMessage = nil
        defer { state.isLoading = false }
        // The status query needs the authorities directory; a cold
        // launch straight into the case screen may not have fetched it
        // yet. Best-effort — a failure surfaces below as status copy.
        try? await repository.refresh()
        do {
            let status = try await repository.caseStatus(
                caseId: caseId,
                mandateRef: mandateRef
            )
            state.status = status
            state.snapshotFetchedAt = nil
        } catch {
            // A stale snapshot (if any) stays rendered; the error only
            // annotates it.
            state.statusErrorMessage = Self.statusMessage(for: error)
        }
    }

    public func submitResponse(_ statement: String) async {
        guard !state.isSubmittingResponse else { return }
        state.isSubmittingResponse = true
        state.responseErrorMessage = nil
        defer { state.isSubmittingResponse = false }
        do {
            state.responseReceipt = try await repository.respond(
                caseId: caseId,
                mandateRef: mandateRef,
                statement: statement
            )
            // Best-effort: pick up responded/responsesOnFile.
            await refresh()
        } catch {
            state.responseErrorMessage = Self.submissionMessage(for: error)
        }
    }

    public func submitAppeal(kind: AppealSubmission.Kind, statement: String) async {
        guard !state.isSubmittingAppeal else { return }
        state.isSubmittingAppeal = true
        state.appealErrorMessage = nil
        defer { state.isSubmittingAppeal = false }
        do {
            state.appealReceipt = try await repository.appeal(
                caseId: caseId,
                mandateRef: mandateRef,
                kind: kind,
                statement: statement
            )
            await refresh()
        } catch {
            state.appealErrorMessage = Self.submissionMessage(for: error)
        }
    }

    // MARK: - Advisory gating

    /// The reference accepts responses on any open case — even late,
    /// flagged `late` — so the composer shows exactly while the case
    /// is open.
    public var canRespond: Bool {
        state.status?.stage == "open"
    }

    /// Appeal affordance: a ban whose review isn't already decided.
    /// From the ban surface it also shows before a status fetch —
    /// the caller holds the verdict, and the Authority is the final
    /// arbiter of the window either way.
    public var showsAppealSection: Bool {
        if let status = state.status {
            guard status.disposition == "ban" else { return false }
            switch status.appealState {
            case nil, "none", "pending": return true
            default: return false
            }
        }
        return banContext
    }

    /// Non-nil when this device's clock says the appeal window has
    /// closed — an annotation, never a hard block: clocks skew, and a
    /// deterministic 410 from the Authority is the honest refusal.
    public var appealDeadlinePassed: Date? {
        guard let deadline = state.status?.appealDeadline,
              now() > deadline else { return nil }
        return deadline
    }

    /// Whether the response deadline has passed per this device's
    /// clock. Advisory: the reference still accepts the filing and
    /// marks it late.
    public var responseDeadlinePassed: Date? {
        guard let deadline = state.status?.responseDeadline,
              now() > deadline else { return nil }
        return deadline
    }

    // MARK: - Error copy

    private static func statusMessage(for error: Error) -> String {
        switch error {
        case ModerationError.caseAccessUnavailable:
            return String(localized: "This case belongs to a different identity on this device. Switch to the identity the case was opened against.")
        case ModerationError.noMandate:
            return String(localized: "The mandate this case was opened under is no longer on this device.")
        case ModerationError.authorityUnavailable:
            return String(localized: "Your authority isn't in the directory right now. Check your connection and try again.")
        case let AuthorityClientError.rejected(rejection) where rejection.statusCode == 404:
            // The reference deliberately answers 404 for unknown case,
            // bad signature, and non-party alike — never present it as
            // proof of anything.
            return String(localized: "The authority didn't serve this case. That can mean a connection or identity problem — it neither confirms nor denies the case.")
        case let AuthorityClientError.rejected(rejection):
            return String(rejection.message.prefix(280))
        default:
            return String(localized: "Couldn't reach your authority for the current status.")
        }
    }

    private static func submissionMessage(for error: Error) -> String {
        switch error {
        case ModerationError.statementInvalid:
            return String(localized: "The statement is empty or exceeds your authority's 16 KB limit.")
        case ModerationError.caseAccessUnavailable:
            return String(localized: "This case belongs to a different identity on this device.")
        case ModerationError.noMandate:
            return String(localized: "The mandate this case was opened under is no longer on this device.")
        case ModerationError.authorityUnavailable:
            return String(localized: "Your authority isn't in the directory right now. Check your connection and try again.")
        case let AuthorityClientError.rejected(rejection) where rejection.statusCode == 410:
            return String(localized: "The appeal window has closed.")
        case let AuthorityClientError.rejected(rejection) where rejection.statusCode == 404:
            return String(localized: "The authority didn't accept this filing. That can mean a connection or identity problem — it neither confirms nor denies the case.")
        case let AuthorityClientError.rejected(rejection):
            // Authority-controlled text (409 case-state and friends);
            // bounded before display.
            return String(rejection.message.prefix(280))
        default:
            return String(localized: "Couldn't deliver the filing. Your signed statement is retained — try again to resend exactly the same content.")
        }
    }
}
