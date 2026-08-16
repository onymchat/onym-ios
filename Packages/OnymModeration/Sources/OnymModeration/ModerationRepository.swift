import Foundation
import CryptoKit
import OSLog

/// Outcome of the most recent authorities-directory fetch. Same
/// shape as `RelayerFetchStatus` so the picker copy stays consistent.
public enum AuthorityFetchStatus: Equatable, Sendable {
    case idle
    case fetching
    case success
    case failed(message: String)
}

/// Whether the active mandate still pins the manifest its authority
/// publishes today.
///
/// A mandate stays valid under the bytes it signed — the reference
/// Authority judges every case under the manifest that mandate pinned,
/// so superseded terms are not an outage and nothing in flight breaks.
/// What they are is stale *consent*: the user is operating under terms
/// the authority no longer stands behind, and only fresh consent can
/// move them onto the new ones.
public enum TermsCurrency: Sendable, Equatable {
    /// Not established yet — no active mandate, the directory hasn't
    /// loaded, or the manifest couldn't be fetched. Never blocks: an
    /// unreachable authority must not lock the user out of the app.
    case unknown
    /// The active mandate's hash equals the published manifest's.
    case current
    /// The authority publishes a different manifest than the one this
    /// mandate consented to.
    case superseded(publishedHash: String)
    /// The active mandate's authority is no longer in the designated
    /// directory. There are no new terms to re-sign — the only way
    /// forward is a different authority.
    case authorityDelisted
}

/// Combined snapshot for consent and settings UI: the designated
/// authorities, the fetch state of that list, and the mandate
/// history for this device.
public struct ModerationState: Sendable, Equatable {
    public let authorities: [AuthorityListing]
    public let fetchStatus: AuthorityFetchStatus
    /// The active record, if the user has consented.
    public let activeMandate: MandateRecord?
    /// Accepted mandates and registration attempts whose outcome is
    /// still ambiguous, newest first. Definitively refused attempts are
    /// not mandates and are removed from this retained state.
    public let history: [MandateRecord]
    /// Result of the most recent `refreshActiveTerms()`.
    public let termsCurrency: TermsCurrency

    public static let empty = ModerationState(
        authorities: [],
        fetchStatus: .idle,
        activeMandate: nil,
        history: []
    )

    public init(
        authorities: [AuthorityListing],
        fetchStatus: AuthorityFetchStatus,
        activeMandate: MandateRecord?,
        history: [MandateRecord],
        termsCurrency: TermsCurrency = .unknown
    ) {
        self.authorities = authorities
        self.fetchStatus = fetchStatus
        self.activeMandate = activeMandate
        self.history = history
        self.termsCurrency = termsCurrency
    }
}

/// A manifest this repository fetched, authenticated, and validated —
/// the unit of consent, mintable only by `manifestForReview(_:)`.
///
/// `SignedManifest` is a plain value with a public initializer, so taking
/// one at signing time would move authenticity (directory-pinned operator
/// key, detached signature over the exact bytes) out of the repository and
/// onto whoever calls it — and a hand-built value can pair `rawBytes` of
/// one manifest with the decoded fields of another, pinning a hash whose
/// contents differ from the classes the mandate enumerates. Wrapping it in
/// a type with no public initializer keeps the check where the invariant
/// lives: the only bytes that can reach a signed mandate are bytes the
/// fetcher verified.
public struct ReviewedManifest: Sendable, Equatable {
    /// The reviewed manifest, for the consent surface to display.
    public let signedManifest: SignedManifest

    init(_ signedManifest: SignedManifest) {
        self.signedManifest = signedManifest
    }
}

/// Owns authority designation + mandate lifecycle: fetches the
/// directory, verifies and pins manifests, signs mandates, and keeps
/// exactly one record active per device. `manifestForReview(_:)` and
/// `consent(to:reviewedManifest:)` form one two-step path for both
/// onboarding and switching — swapping authorities *is* signing a
/// fresh mandate (Moderation.md §5.3).
public actor ModerationRepository {
    /// This interface's component id, carried in every mandate.
    public static let interfaceComponentId = "onym:component:onym-ios"

    private static let logger = Logger(
        subsystem: "app.onym.ios", category: "moderation"
    )

    /// Retention bound on the report ledger. Rows whose delivery is
    /// still ambiguous (no receipt) are always kept — they are the
    /// idempotency keys for exact retry — but resolved rows beyond this
    /// count are pruned oldest-first so disclosed content doesn't
    /// accumulate indefinitely.
    public static let maxResolvedReportRecords = 128

    /// Reference Authority's cap on a statement body
    /// (`MAX_STATEMENT_BYTES`). Checked client-side so an oversize
    /// statement fails fast with a usable message instead of a 400.
    public static let maxStatementBytes = 16_384

    /// Retention bound on resolved case-submission ledger rows, same
    /// scheme as `maxResolvedReportRecords`: acknowledged rows prune
    /// oldest-first.
    public static let maxResolvedCaseSubmissions = 128

    /// Bound on pending (unacknowledged) submission rows. Unlike report
    /// rows, dropping one cannot mint a duplicate allegation — the
    /// reference doesn't deduplicate submissions anyway — so a
    /// generous cap beats unbounded statement text accumulating from
    /// edited retries while the Authority is unreachable.
    public static let maxPendingCaseSubmissions = 128

    /// Retention bound on cached case-status snapshots. Snapshots
    /// upsert by caseId, so the set grows only with distinct cases
    /// against this device's identities; the bound is a backstop, and
    /// the oldest fetch falls off first.
    public static let maxCaseStatusRecords = 64

    private let authoritiesFetcher: any KnownAuthoritiesFetcher
    private let manifestFetcher: any AuthorityManifestFetcher
    private let manifestValidator: AuthorityManifestValidator
    private let mandateStore: any MandateStore
    private let reportStore: any ReportFilingStore
    private let caseStore: any CaseStatusStore
    private let caseSubmissionStore: any CaseSubmissionStore
    private let backend: any EnforcementBackendClient
    private let authorityClients: any ModerationAuthorityClientFactory
    private let attestation: any DeviceAttestationProvider
    private let signer: any ModerationSigner
    private let clock: @Sendable () -> Date

    private struct ConsentKey: Hashable {
        let authority: String
        let user: String
        let manifestHash: String
    }

    /// Exact persisted registration artifact. `mandateBytes` includes
    /// both signatures; `createdAt` distinguishes two locally retained
    /// records whose signed bytes happen to be identical.
    private struct RegistrationKey: Hashable {
        let mandateBytes: Data
        let createdAt: Date
    }

    private struct RegistrationFlight {
        let task: Task<MandateRegistrationReceipt, Error>
        var waiters: Int
    }

    private struct ReportKey: Hashable {
        let authority: String
        let reporter: String
        let accused: String
        let classId: String
        let messageId: String
    }

    private struct CaseStatusKey: Hashable {
        let authority: String
        let user: String
        let caseId: String
    }

    private struct CaseSubmissionKey: Hashable {
        let authority: String
        let user: String
        let caseId: String
        let mandateRef: String
        let kind: CaseSubmissionRecord.Kind
        let statementHash: String
    }

    private var authorities: [AuthorityListing] = []
    private var fetchStatus: AuthorityFetchStatus = .idle
    private var records: [MandateRecord]
    private var reportRecords: [ReportFilingRecord]
    private var caseRecords: [CaseStatusRecord]
    private var caseSubmissions: [CaseSubmissionRecord]
    private var continuations: [UUID: AsyncStream<ModerationState>.Continuation] = [:]
    private var startTask: Task<Void, Never>?
    private var consentTasks: [ConsentKey: Task<MandateRecord, Error>] = [:]
    private var registrationFlights: [RegistrationKey: RegistrationFlight] = [:]
    private var reportTasks: [ReportKey: Task<ReportReceipt, Error>] = [:]
    private var caseStatusTasks: [CaseStatusKey: Task<CaseStatus, Error>] = [:]
    private var caseResponseTasks: [CaseSubmissionKey: Task<CaseResponseReceipt, Error>] = [:]
    private var caseAppealTasks: [CaseSubmissionKey: Task<AppealReceipt, Error>] = [:]
    private var refreshTask: Task<[AuthorityListing], Error>?
    private var termsCheckTask: Task<Void, Never>?
    /// Last authenticated, consentable manifest seen for an authority,
    /// and the authority the directory has stopped listing. Each holds
    /// one authority, not a table: they are observations about the one
    /// the active mandate names, and are only ever read through
    /// `termsCurrency`, which discards them when they describe anyone
    /// else. Reading either directly would need that check restated.
    private var publishedManifest: (authority: String, hash: String)?
    private var delistedAuthority: String?

    public init(
        authoritiesFetcher: any KnownAuthoritiesFetcher,
        manifestFetcher: any AuthorityManifestFetcher,
        mandateStore: any MandateStore,
        reportStore: any ReportFilingStore = UserDefaultsReportFilingStore(),
        caseStore: any CaseStatusStore = UserDefaultsCaseStatusStore(),
        caseSubmissionStore: any CaseSubmissionStore = UserDefaultsCaseSubmissionStore(),
        backend: any EnforcementBackendClient,
        authorityClients: any ModerationAuthorityClientFactory,
        attestation: any DeviceAttestationProvider,
        signer: any ModerationSigner,
        manifestValidator: AuthorityManifestValidator = AuthorityManifestValidator(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authoritiesFetcher = authoritiesFetcher
        self.manifestFetcher = manifestFetcher
        self.manifestValidator = manifestValidator
        self.mandateStore = mandateStore
        self.reportStore = reportStore
        self.caseStore = caseStore
        self.caseSubmissionStore = caseSubmissionStore
        self.backend = backend
        self.authorityClients = authorityClients
        self.attestation = attestation
        self.signer = signer
        self.clock = clock
        self.records = mandateStore.load()
        self.reportRecords = reportStore.load()
        self.caseRecords = caseStore.load()
        self.caseSubmissions = caseSubmissionStore.load()
    }

    // MARK: - Directory refresh

    /// Background refresh of the designated-authorities list.
    /// Idempotent; failures leave the (empty or previous) list alone.
    public func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.refresh()
                try await self.retryNewestPendingRegistration()
            } catch {
                // Directory and registration retry state are already
                // published/persisted by their individual operations.
                // A later consent attempt resumes safely.
            }
            await self.checkTermsIfNotYetEstablished()
        }
    }

    /// An install whose active mandate only appears when a pending
    /// registration resolves has already missed the launch terms check,
    /// which returned immediately on finding no active record. Nothing
    /// else re-triggers one, so those installs would run unchecked
    /// until the next foreground. Narrow by design: it does nothing
    /// when a check has already produced an answer for the record that
    /// is active now.
    private func checkTermsIfNotYetEstablished() async {
        guard activeMandateRecord() != nil, termsCurrency == .unknown else { return }
        await refreshActiveTerms()
    }

    /// Fetch the latest directory. Throws so consent UI can surface
    /// failure with a retry affordance.
    ///
    /// One fetch at a time, shared by every caller: launch, the consent
    /// flow, and the terms check all ask for the directory within the
    /// same moment of a cold start. Racing fetches let a loser's
    /// `.failed` land after a winner's `.success` and put a spurious
    /// "Couldn't load the authority list." under the onboarding picker.
    public func refresh() async throws {
        _ = try await refreshedAuthorities()
    }

    /// `refresh()` for callers that need to act on the list it fetched.
    /// The list comes back as a value rather than being read off the
    /// actor afterwards: with fetches coalesced, another caller can
    /// start a new one in the suspension between this task finishing
    /// and its awaiter resuming, so `fetchStatus` at that point may
    /// describe a fetch that has nothing to do with this call.
    @discardableResult
    private func refreshedAuthorities() async throws -> [AuthorityListing] {
        if let task = refreshTask {
            return try await task.value
        }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        return try await task.value
    }

    private func performRefresh() async throws -> [AuthorityListing] {
        // A list already on screen is not replaced by a spinner for a
        // background re-read, and is not replaced by an error if that
        // read fails. The terms check re-reads the directory on every
        // foreground, and without this the consent picker — which is
        // exactly what is on screen when the re-consent gate is up —
        // would flicker through its loading and failure affordances on
        // each resume.
        let hadList = fetchStatus == .success
        if !hadList {
            fetchStatus = .fetching
            publish()
        }
        do {
            authorities = try await authoritiesFetcher.fetchLatest()
            fetchStatus = .success
        } catch {
            // Cleared before the task's value becomes available, so a
            // caller that arrives while this one is finishing starts a
            // fresh fetch instead of awaiting a settled one.
            refreshTask = nil
            if hadList {
                Self.logger.debug("directory re-read failed; keeping the list already loaded")
            } else {
                fetchStatus = .failed(
                    message: String(localized: "Couldn't load the authority list.")
                )
                publish()
            }
            throw error
        }
        refreshTask = nil
        // Every successful directory read is evidence about the active
        // mandate's authority, wherever it was asked for. The consent
        // flow refreshes on appear and on its retry button without ever
        // going through the terms check, so leaving reconciliation
        // there let a stale `publishedManifest` outlive the listing it
        // came from — an undismissable "these terms have changed" over
        // a picker reading "No authorities are published yet", with no
        // remedy on screen.
        reconcileDirectoryWithActiveMandate()
        publish()
        return authorities
    }

    private func reconcileDirectoryWithActiveMandate() {
        guard let record = activeMandateRecord() else { return }
        if authorities.contains(where: { $0.componentId == record.mandate.authority }) {
            noteAuthorityListed(record.mandate.authority)
        } else {
            noteAuthorityDelisted(record.mandate.authority)
        }
    }

    // MARK: - Terms currency

    /// Re-establish whether the active mandate still pins the manifest
    /// its authority publishes today. Called on app open and on every
    /// return to the foreground.
    ///
    /// Never throws and never blocks the app on a bad answer: an
    /// unreachable authority, a directory that hasn't loaded, or a
    /// manifest that fails verification all leave the last known
    /// currency in place. Only a manifest that authenticates and hashes
    /// to something other than the mandate's can supersede it — a
    /// forged or corrupted document must not be able to push the user
    /// into re-signing.
    ///
    /// Idempotent while in flight: overlapping calls (launch racing the
    /// first foreground notification) share one check.
    public func refreshActiveTerms() async {
        if let task = termsCheckTask {
            // A foreground arriving mid-check takes that check's answer
            // even though its fetches may predate the backgrounding. A
            // deliberate gap: the alternative is queueing a second full
            // round of fetches behind every one already running, and
            // the verdict this returns is at worst one foreground
            // stale, which the next one corrects.
            await task.value
            return
        }
        let task = Task { await self.runTermsCheck() }
        termsCheckTask = task
        await task.value
    }

    /// Clears the in-flight marker *before* returning, so it is already
    /// nil by the time any awaiter resumes. Clearing after `await
    /// task.value` in the caller instead would leave a suspension-wide
    /// window in which an arriving foreground event joins a finished
    /// check, returns its stale verdict, and never runs one of its own.
    private func runTermsCheck() async {
        await performTermsCheck()
        termsCheckTask = nil
    }

    private func performTermsCheck() async {
        guard let record = activeMandateRecord() else { return }
        // Always re-read the directory, not just when it has never
        // loaded. It is what says the authority is still designated,
        // and it carries the operator key the manifest below is
        // authenticated against — a cached copy makes delisting a
        // cold-start-only discovery and pins the check to a key that
        // may since have rotated. Callers share one fetch, so a
        // foreground that races the launch check costs nothing.
        guard let listings = try? await refreshedAuthorities() else { return }

        // Listing and delisting were both settled by the refresh above,
        // which reconciles them for every caller. Presence is the same
        // quality of answer as absence and is recorded the moment the
        // directory lands — never held hostage to the manifest fetch
        // below, which would leave a relisted authority whose manifest
        // momentarily fails to fetch showing "Authority Unavailable",
        // offering only the remedy of switching away from an authority
        // the directory does list.
        guard let listing = listings.first(where: {
            $0.componentId == record.mandate.authority
        }) else { return }

        let published: SignedManifest
        do {
            published = try await manifestFetcher.fetch(listing)
        } catch {
            Self.logger.debug("terms check: manifest unavailable, keeping last known currency")
            return
        }
        // Terms that cannot be consented to must not supersede consent.
        // The same validity conditions gate signing, so an authority
        // republishing an expired or unsupported manifest would
        // otherwise gate every install on a re-consent whose only
        // remedy — reviewing those very bytes — `manifestForReview`
        // then refuses. Leaving the mandate current is both the honest
        // reading (nothing consentable has replaced it) and the only
        // one with a way out.
        do {
            try manifestValidator.validateForConsent(published, now: clock())
        } catch {
            Self.logger.debug("terms check: published manifest is not consentable, ignoring")
            return
        }
        notePublishedManifest(published.manifestHash, for: listing.componentId)
    }

    // MARK: Derived currency

    /// Currency is *derived* from the last authenticated observation and
    /// whichever record is active right now — never latched at the
    /// moments consent happens to pass through. Every path that can
    /// activate a record (fresh consent, a resolved pending
    /// registration, a retried one) would otherwise have to remember to
    /// update it, and the one that forgot would strand the user on an
    /// undismissable gate.
    private var termsCurrency: TermsCurrency {
        guard let record = activeMandateRecord() else { return .unknown }
        if delistedAuthority == record.mandate.authority { return .authorityDelisted }
        guard let observed = publishedManifest,
              observed.authority == record.mandate.authority
        else { return .unknown }
        return observed.hash == record.mandate.manifestHash
            ? .current
            : .superseded(publishedHash: observed.hash)
    }

    private func notePublishedManifest(_ hash: String, for authority: String) {
        let before = termsCurrency
        publishedManifest = (authority: authority, hash: hash)
        if delistedAuthority == authority { delistedAuthority = nil }
        if termsCurrency != before { publish() }
    }

    private func noteAuthorityListed(_ authority: String) {
        guard delistedAuthority == authority else { return }
        let before = termsCurrency
        delistedAuthority = nil
        if termsCurrency != before { publish() }
    }

    private func noteAuthorityDelisted(_ authority: String) {
        let before = termsCurrency
        delistedAuthority = authority
        if publishedManifest?.authority == authority { publishedManifest = nil }
        if termsCurrency != before { publish() }
    }

    // MARK: - Consent

    /// Fetch, verify, and validate the exact manifest bytes to put on the
    /// consent surface. The returned value is the unit of consent: callers
    /// must retain it and pass that same value to
    /// `consent(to:reviewedManifest:)` after the user agrees.
    public func manifestForReview(_ listing: AuthorityListing) async throws -> ReviewedManifest {
        let signedManifest = try await manifestFetcher.fetch(listing)
        try manifestValidator.validateForConsent(signedManifest, now: clock())
        return ReviewedManifest(signedManifest)
    }

    /// Consent to the exact manifest the user reviewed: validate it again
    /// at signing time, pin its already-computed hash and raw bytes, enroll
    /// this device, sign the mandate, obtain the interface countersignature,
    /// register those exact bytes with the Authority, and only then activate
    /// the local record. This method deliberately never refetches the manifest;
    /// an authority changing its hosted terms between review and agreement
    /// therefore cannot replace the artifact that gets signed.
    ///
    /// Any previously active record is deactivated untouched — its mandate
    /// stays bound to the manifest hash it consented to, forever.
    @discardableResult
    public func consent(
        to listing: AuthorityListing,
        reviewedManifest: ReviewedManifest
    ) async throws -> MandateRecord {
        let signedManifest = reviewedManifest.signedManifest
        let userKey = try await signer.userKeyID()
        let key = ConsentKey(
            authority: listing.componentId,
            user: userKey,
            manifestHash: signedManifest.manifestHash
        )

        // Actor methods are reentrant at every network await. Share one
        // consent task per user/authority/manifest so overlapping taps
        // cannot both pass the pending lookup and mint two artifacts.
        if let task = consentTasks[key] {
            return try await task.value
        }
        let task = Task {
            try await self.performConsent(
                to: listing,
                reviewedManifest: reviewedManifest,
                userKey: userKey
            )
        }
        consentTasks[key] = task
        do {
            let record = try await task.value
            consentTasks.removeValue(forKey: key)
            return record
        } catch {
            consentTasks.removeValue(forKey: key)
            throw error
        }
    }

    private func performConsent(
        to listing: AuthorityListing,
        reviewedManifest: ReviewedManifest,
        userKey: String
    ) async throws -> MandateRecord {
        let signedManifest = reviewedManifest.signedManifest
        guard signedManifest.manifest.componentId == listing.componentId else {
            throw ModerationError.manifestInvalid(
                "reviewed manifest componentId does not match the selected authority"
            )
        }

        // Validity conditions (validUntil, supported profile, external
        // appellate for permanent classes) gate enrollment and signing —
        // not just the consent UI. An invalid manifest must never end up
        // pinned by a signed mandate.
        try manifestValidator.validateForConsent(signedManifest, now: clock())

        // Resolve every older ambiguous registration for this Authority
        // before minting under newly reviewed terms. A manifest rotation
        // must not orphan hidden pending bytes or create a replacement
        // while the old request may already have committed.
        while let pending = records.first(where: {
            $0.mandate.authority == listing.componentId
                && $0.mandate.user == userKey
                && $0.registrationPending
        }) {
            if pending.mandate.manifestHash == signedManifest.manifestHash {
                return try await activate(pending, with: listing, publishing: signedManifest)
            }
            do {
                _ = try await registerPending(pending, with: listing, activate: false)
            } catch {
                // A definitive refusal removes the old attempt, so the
                // consent the user just gave to the new manifest may
                // proceed. Ambiguous outcomes still block replacement.
                guard isDeterministicRegistrationRejection(error) else {
                    throw error
                }
            }
        }

        // Enrollment: (identity signature, device token) presented
        // together is the only token↔enrollment linkage. A nil token
        // (simulator) still enrolls — the backend decides what that
        // means; the client never fabricates one.
        let token: Data?
        if attestation.isSupported {
            token = try? await attestation.generateToken()
        } else {
            token = nil
        }
        // The signed bytes are built from exactly the fields the
        // request transmits, so the backend can recompute and verify
        // them — the timestamp travels with the signature it covers.
        let enrollmentTimestamp = clock()
        let enrollmentSignature = try await signer.sign(
            EnrollmentRequest.signedPayload(
                deviceToken: token,
                userKey: userKey,
                timestamp: enrollmentTimestamp
            )
        )
        let enrollment = try await backend.enrollDevice(
            EnrollmentRequest(
                deviceToken: token,
                userKey: userKey,
                timestamp: enrollmentTimestamp,
                signature: enrollmentSignature
            )
        )

        var mandate = ModerationMandate(
            user: userKey,
            interface: Self.interfaceComponentId,
            authority: listing.componentId,
            manifestHash: signedManifest.manifestHash,
            classes: signedManifest.manifest.violationClasses.map(\.classId),
            deviceBinding: enrollment.deviceBinding,
            acceptedAt: clock()
        )
        let userSignature = try await signer.sign(mandate.signingBytes())
        mandate.signatures = [userSignature.base64EncodedString()]

        // The countersignature is appended to the client's own copy.
        // The backend never hands back a mandate, so no consented
        // field can change behind the user's signature.
        let countersignature = try await backend.countersignMandate(mandate)
        let isCountersigned: Bool
        if countersignature.signature == StubEnforcementBackendClient.countersignSentinel {
            isCountersigned = false
        } else {
            // Minimum plausibility before recording a countersigned
            // mandate: a 64-byte base64 Ed25519 signature. A live
            // backend answering an empty or garbage string must not
            // mint an "active, countersigned" record. (Cryptographic
            // verification needs the interface key distributed out of
            // band — the Authority verifies it in full at
            // registration.)
            guard let raw = Data(base64Encoded: countersignature.signature),
                  raw.count == 64 else {
                throw ModerationError.countersignatureInvalid(
                    "interface countersignature is not a 64-byte Ed25519 signature"
                )
            }
            isCountersigned = true
        }
        mandate.signatures = [
            userSignature.base64EncodedString(),
            countersignature.signature,
        ]

        let record = MandateRecord(
            mandate: mandate,
            manifestBytes: signedManifest.rawBytes,
            authorityName: listing.name,
            countersigned: isCountersigned,
            authorityRegistered: false,
            // The sentinel exists only for UI/dev scenarios with no
            // deployed Interface or Authority. Preserve that explicit
            // nonconforming scaffold, but never send it to an Authority.
            isActive: !isCountersigned,
            createdAt: clock()
        )

        if isCountersigned {
            // Persist before the network hop. If the Authority commits
            // and its response is lost, the next attempt resends this
            // exact mandate rather than signing another one.
            records.insert(record, at: 0)
            mandateStore.save(records)
            publish()
            return try await activate(record, with: listing, publishing: signedManifest)
        }

        // Deactivate the previous active record without touching
        // anything else in it (mandates are immutable, spec §12).
        records = records.map { existing in
            var existing = existing
            existing.isActive = false
            return existing
        }
        records.insert(record, at: 0)
        mandateStore.save(records)
        noteConsentedManifest(signedManifest, for: listing)
        publish()
        return record
    }

    /// Register a pending record and, once it is actually the active
    /// one, record the manifest it consented to.
    ///
    /// The observation belongs *at* activation, not before it. Recorded
    /// earlier, it would drop the undismissable gate while this method
    /// is still enrolling and signing — a failure after that point
    /// returns the user to the app under the stale mandate, ungated,
    /// never seeing the error. Recorded earlier but withheld for other
    /// authorities (the previous shape of this) it would survive a
    /// switch away and describe an authority no record names, ready to
    /// fire a false `.superseded` against a stale hash if the user ever
    /// switched back. Tying it to activation gives both properties for
    /// free: no observation outlives the record it describes, and none
    /// exists before one does.
    private func activate(
        _ record: MandateRecord,
        with listing: AuthorityListing,
        publishing signedManifest: SignedManifest
    ) async throws -> MandateRecord {
        let activated = try await registerPending(record, with: listing, activate: true)
        noteConsentedManifest(signedManifest, for: listing)
        return activated
    }

    /// These bytes were fetched, authenticated, and validated moments
    /// ago, so they are the freshest observation this repository has of
    /// what the authority publishes — and the record that just became
    /// active pins them, so derived currency reads `.current` without
    /// anyone having to say so.
    private func noteConsentedManifest(
        _ signedManifest: SignedManifest,
        for listing: AuthorityListing
    ) {
        notePublishedManifest(signedManifest.manifestHash, for: listing.componentId)
    }

    // MARK: - Read

    public func activeMandateRecord() -> MandateRecord? {
        records.first { $0.isActive }
    }

    public func currentState() -> ModerationState {
        ModerationState(
            authorities: authorities,
            fetchStatus: fetchStatus,
            activeMandate: activeMandateRecord(),
            history: records,
            termsCurrency: termsCurrency
        )
    }

    /// Recover the banned case IDs belonging to the retained active
    /// identity. The Authority authenticates the lookup with that identity
    /// and returns IDs only; details still require the case-status request.
    public func recoverableCaseIDs() async throws -> [String] {
        try await recoveryAuthorityClient().queryRecoverableCases()
    }

    /// File a device-recovery claim (§6) with the active mandate's
    /// authority: the contact a moderator can verify the holder
    /// through, and the holder's account of how they hold the marked
    /// device. Signed by the current (new) identity — the grantee a
    /// grant would name. Returns the claim id to poll.
    public func fileDeviceRecoveryClaim(contact: String, statement: String) async throws -> String {
        try await recoveryAuthorityClient().fileRecoveryClaim(contact: contact, statement: statement)
    }

    /// Where a filed device-recovery claim stands; carries the signed
    /// grant once a moderator issues one.
    public func deviceRecoveryClaimStatus(claimId: String) async throws -> RecoveryClaimStatus {
        try await recoveryAuthorityClient().recoveryClaimStatus(claimId: claimId)
    }

    private func recoveryAuthorityClient() throws -> any ModerationAuthorityClient {
        guard let record = activeMandateRecord() else {
            throw ModerationError.noMandate
        }
        guard let listing = authorities.first(where: {
            $0.componentId == record.mandate.authority
        }) else {
            throw ModerationError.authorityUnavailable(record.mandate.authority)
        }
        return authorityClients.client(for: listing)
    }

    /// Retry one persisted registration attempt without minting or
    /// signing anything new. A later consent always wins: resolving an
    /// older artifact records it as history rather than silently making
    /// its Authority current again.
    @discardableResult
    public func retryRegistration(_ pending: MandateRecord) async throws -> MandateRecord {
        guard let storedIndex = recordIndex(of: pending) else {
            throw ModerationError.registrationNotPending
        }
        guard records[storedIndex].registrationPending else {
            return records[storedIndex]
        }
        guard let listing = authorities.first(where: {
            $0.componentId == pending.mandate.authority
        }) else {
            throw ModerationError.authorityUnavailable(pending.mandate.authority)
        }
        return try await registerPending(
            pending,
            with: listing,
            activate: shouldActivateResolvedPending(pending)
        )
    }

    // MARK: - Reporting

    /// Violation classes the current Authority declared and the user
    /// consented to. The report UI presents these exact class IDs; the
    /// Authority still independently checks the accused mandate.
    public func availableReportClasses() throws -> [ViolationClass] {
        let record = try activeReportingMandate()
        guard let manifest = record.consentedManifest()?.manifest else {
            throw ModerationError.reportingUnavailable("consented manifest is unavailable")
        }
        return manifest.violationClasses.filter {
            record.mandate.classes.contains($0.classId)
        }
    }

    /// File one recipient-held text message with the currently selected
    /// Authority. The report is signed and persisted before delivery;
    /// ambiguous retries reuse byte-identical JSON and the same reportId.
    @discardableResult
    public func fileReport(
        message: ReportableMessage,
        classId: String
    ) async throws -> ReportReceipt {
        let mandate = try activeReportingMandate()
        let key = ReportKey(
            authority: mandate.mandate.authority,
            reporter: mandate.mandate.user,
            accused: message.accused,
            classId: classId,
            messageId: message.id
        )
        if let task = reportTasks[key] {
            return try await task.value
        }
        let task = Task {
            try await self.performFileReport(
                message: message,
                classId: classId,
                reporterMandate: mandate
            )
        }
        reportTasks[key] = task
        do {
            let receipt = try await task.value
            reportTasks.removeValue(forKey: key)
            return receipt
        } catch {
            reportTasks.removeValue(forKey: key)
            throw error
        }
    }

    // MARK: - Case status (accused side)

    /// The retained mandate a case references, resolved from history by
    /// content hash. Standing in a case follows the mandate it was
    /// opened under — NOT the currently active record: switching
    /// authorities deactivates the old mandate but must not strand the
    /// user out of a case that mandate still governs (mandates are
    /// immutable, spec §12).
    public func mandateRecord(forRef ref: String) -> MandateRecord? {
        records.first { (try? $0.mandate.mandateHash()) == ref }
    }

    /// Fetch the authenticated status document for one case, persist it
    /// as the offline snapshot, and return it. Fails closed when the
    /// referenced mandate is not retained, the active identity does not
    /// own it, or its Authority is absent from the directory.
    ///
    /// The reference Authority deliberately answers 404 for unknown
    /// case, bad signature, and non-party alike (a case id must not be
    /// an existence oracle), so callers cannot distinguish those —
    /// surface 404 as "case unavailable", never as proof of anything.
    public func caseStatus(caseId: String, mandateRef: String) async throws -> CaseStatus {
        let (record, listing) = try await caseStanding(mandateRef: mandateRef)
        let key = CaseStatusKey(
            authority: listing.componentId,
            user: record.mandate.user,
            caseId: caseId
        )
        if let task = caseStatusTasks[key] {
            return try await task.value
        }
        let task = Task {
            try await self.performCaseStatus(
                caseId: caseId,
                mandateRef: mandateRef,
                record: record,
                listing: listing
            )
        }
        caseStatusTasks[key] = task
        do {
            let status = try await task.value
            caseStatusTasks.removeValue(forKey: key)
            return status
        } catch {
            caseStatusTasks.removeValue(forKey: key)
            throw error
        }
    }

    /// The last fetched snapshot for a case, if any — for rendering
    /// offline or before the first fetch of a session completes.
    /// Owner-checked: a snapshot persisted for another local
    /// identity's case never leaves the repository, so no caller can
    /// render foreign case content while a network fetch is in flight.
    public func storedCaseStatus(caseId: String) async -> CaseStatusRecord? {
        guard let record = caseRecords.first(where: { $0.caseId == caseId }) else {
            return nil
        }
        guard let userKey = try? await signer.userKeyID(),
              record.user == userKey else {
            return nil
        }
        return record
    }

    /// Drop every case snapshot not owned by one of `users`
    /// (`onym:key:<hex>` references). Called on identity removal, same
    /// contract as `purgeReportRecords(keepingReporters:)`.
    public func purgeCaseStatusRecords(keepingUsers users: Set<String>) {
        let before = caseRecords.count
        caseRecords.removeAll { !users.contains($0.user) }
        guard caseRecords.count != before else { return }
        try? caseStore.save(caseRecords)
    }

    /// Standing for any accused-side case operation: the case's mandate
    /// must be retained, owned by the active identity, and its
    /// Authority resolvable in the current directory.
    /// `requireOwnership: false` exists for one caller: a new-holder
    /// claim, whose premise is that the device's current holder is NOT
    /// the mandated user (the reference accepts it unsigned for the
    /// same reason). Everything else must own the mandate it acts under.
    private func caseStanding(
        mandateRef: String,
        requireOwnership: Bool = true
    ) async throws -> (MandateRecord, AuthorityListing) {
        guard let record = mandateRecord(forRef: mandateRef) else {
            throw ModerationError.noMandate
        }
        if requireOwnership {
            let userKey = try await signer.userKeyID()
            guard userKey == record.mandate.user else {
                throw ModerationError.caseAccessUnavailable(
                    "active identity does not own the case's mandate"
                )
            }
        }
        guard let listing = authorities.first(where: {
            $0.componentId == record.mandate.authority
        }) else {
            throw ModerationError.authorityUnavailable(record.mandate.authority)
        }
        return (record, listing)
    }

    private func performCaseStatus(
        caseId: String,
        mandateRef: String,
        record: MandateRecord,
        listing: AuthorityListing
    ) async throws -> CaseStatus {
        let client = authorityClients.client(for: listing)
        let status = try await client.queryStatus(caseId: caseId)
        // The concrete HTTP client correlates this too; repeating the
        // check here preserves the invariant for every factory-injected
        // implementation of the protocol.
        guard status.caseId == caseId else {
            throw AuthorityClientError.caseIdentifierMismatch(
                expected: caseId,
                received: status.caseId
            )
        }
        let snapshot = CaseStatusRecord(
            caseId: caseId,
            mandateRef: mandateRef,
            user: record.mandate.user,
            status: status,
            fetchedAt: clock()
        )
        if let index = caseRecords.firstIndex(where: { $0.caseId == caseId }) {
            caseRecords[index] = snapshot
        } else {
            caseRecords.insert(snapshot, at: 0)
        }
        if caseRecords.count > Self.maxCaseStatusRecords {
            caseRecords.sort { $0.fetchedAt > $1.fetchedAt }
            caseRecords.removeLast(caseRecords.count - Self.maxCaseStatusRecords)
        }
        do {
            try caseStore.save(caseRecords)
        } catch {
            // The snapshot is a cache; the Authority's answer is
            // authoritative and must reach the caller. Error only —
            // no case content — per no-activity-logging.
            Self.logger.error("case snapshot persistence failed: \(error)")
        }
        return status
    }

    // MARK: - Case submissions (accused side)

    /// File the accused's signed statement on an open case. Standing
    /// follows the case's mandate (resolved by reference, owned by the
    /// active identity). The signed artifact is persisted before
    /// delivery and ambiguous outcomes retry byte-identically; an
    /// identical statement re-submitted after an acknowledgment returns
    /// the stored receipt instead of re-delivering — the reference
    /// Authority does NOT deduplicate responses (every delivery files
    /// a new row, bounded at 32 per case), so this client-side ledger
    /// is the only double-file protection.
    ///
    /// The reference enforces no response deadline: a late statement
    /// is accepted and flagged (`receipt.late`), never refused. Client
    /// deadline gating is therefore advisory UI, not enforcement.
    @discardableResult
    public func respond(
        caseId: String,
        mandateRef: String,
        statement: String
    ) async throws -> CaseResponseReceipt {
        let statement = try Self.validatedStatement(statement)
        let (record, listing) = try await caseStanding(mandateRef: mandateRef)
        let key = CaseSubmissionKey(
            authority: listing.componentId,
            user: record.mandate.user,
            caseId: caseId,
            mandateRef: mandateRef,
            kind: .response,
            statementHash: Self.statementHash(statement)
        )
        if let task = caseResponseTasks[key] {
            return try await task.value
        }
        let task = Task {
            try await self.performRespond(
                caseId: caseId,
                mandateRef: mandateRef,
                statement: statement,
                record: record,
                listing: listing
            )
        }
        caseResponseTasks[key] = task
        // The flight key is released by a janitor task AFTER delivery
        // completes — not by a caller-side defer, which a cancelled
        // awaiting caller would run while the unstructured delivery
        // task keeps going, letting a second call start a concurrent
        // duplicate delivery against a server with no idempotency
        // token. (A completed task lingering briefly in the dictionary
        // is harmless: new callers receive its settled result.)
        Task {
            _ = try? await task.value
            self.caseResponseTasks.removeValue(forKey: key)
        }
        return try await task.value
    }

    /// File an appeal (`.appeal`, signed, gated server-side on a ban
    /// with an open appeal window) or a new-holder claim
    /// (`.newHolderClaim`, which the reference accepts unsigned and
    /// answers 200 unconditionally — `receipt.filed` never proves the
    /// claim was recorded). Same persist-before-deliver / exact-retry /
    /// single-flight discipline as `respond`.
    @discardableResult
    public func appeal(
        caseId: String,
        mandateRef: String,
        kind: AppealSubmission.Kind,
        statement: String
    ) async throws -> AppealReceipt {
        let statement = try Self.validatedStatement(statement)
        // A new-holder claim is definitionally filed by someone who is
        // not the mandated user; ownership is not required for it.
        // Scope note: standing still resolves the former holder's
        // mandate from local history, so this path serves the
        // same-device case where that record is retained. A fresh
        // holder with nothing retained files from the ban surface,
        // which has the verdict (and its mandateRef/authority) in
        // hand — that flow lands with the case UI.
        let (record, listing) = try await caseStanding(
            mandateRef: mandateRef,
            requireOwnership: kind == .appeal
        )
        // The ledger row belongs to the identity that FILED it — for a
        // new-holder claim that is the device's current identity, not
        // the mandated (previous) holder, whose key is by premise not
        // local and would make the identity-removal purge silently
        // drop a pending claim's retry artifact.
        let submittingUser: String
        if kind == .appeal {
            submittingUser = record.mandate.user
        } else {
            submittingUser = try await signer.userKeyID()
        }
        let recordKind: CaseSubmissionRecord.Kind =
            kind == .appeal ? .appeal : .newHolderClaim
        let key = CaseSubmissionKey(
            authority: listing.componentId,
            user: submittingUser,
            caseId: caseId,
            mandateRef: mandateRef,
            kind: recordKind,
            statementHash: Self.statementHash(statement)
        )
        if let task = caseAppealTasks[key] {
            return try await task.value
        }
        let task = Task {
            try await self.performAppeal(
                caseId: caseId,
                mandateRef: mandateRef,
                kind: kind,
                recordKind: recordKind,
                statement: statement,
                submittingUser: submittingUser,
                listing: listing
            )
        }
        caseAppealTasks[key] = task
        // Same janitor-cleanup rationale as `respond`.
        Task {
            _ = try? await task.value
            self.caseAppealTasks.removeValue(forKey: key)
        }
        return try await task.value
    }

    /// Ledger rows for one case, newest first — pending rows are the
    /// retry artifacts, acknowledged rows the filing history.
    public func caseSubmissions(caseId: String) -> [CaseSubmissionRecord] {
        caseSubmissions.filter { $0.caseId == caseId }
    }

    /// Same contract as the other ledgers: drop every submission not
    /// owned by one of `users` when an identity is removed.
    public func purgeCaseSubmissionRecords(keepingUsers users: Set<String>) {
        let before = caseSubmissions.count
        caseSubmissions.removeAll { !users.contains($0.user) }
        guard caseSubmissions.count != before else { return }
        try? caseSubmissionStore.save(caseSubmissions)
    }

    private func performRespond(
        caseId: String,
        mandateRef: String,
        statement: String,
        record: MandateRecord,
        listing: AuthorityListing
    ) async throws -> CaseResponseReceipt {
        if let existing = caseSubmissions.first(where: {
            $0.kind == .response
                && $0.caseId == caseId
                && $0.user == record.mandate.user
                && $0.mandateRef == mandateRef
                && $0.response?.statement == statement
        }) {
            if let receipt = existing.responseReceipt { return receipt }
            return try await deliverResponse(existing, to: listing)
        }

        var response = CaseResponse(
            caseId: caseId,
            statement: statement,
            evidence: []
        )
        // Signed as the mandate's identity — the case is bound to
        // `mandate.user`, which may not be the selected identity.
        response.signature = try await signer
            .sign(response.signingBytes(), as: record.mandate.user)
            .base64EncodedString()
        let submission = CaseSubmissionRecord(
            caseId: caseId,
            mandateRef: mandateRef,
            user: record.mandate.user,
            authorityName: listing.name,
            kind: .response,
            response: response,
            createdAt: clock()
        )
        try persistNewSubmission(submission)
        return try await deliverResponse(submission, to: listing)
    }

    private func performAppeal(
        caseId: String,
        mandateRef: String,
        kind: AppealSubmission.Kind,
        recordKind: CaseSubmissionRecord.Kind,
        statement: String,
        submittingUser: String,
        listing: AuthorityListing
    ) async throws -> AppealReceipt {
        if let existing = caseSubmissions.first(where: {
            $0.kind == recordKind
                && $0.caseId == caseId
                && $0.user == submittingUser
                && $0.mandateRef == mandateRef
                && $0.appeal?.statement == statement
        }) {
            if let receipt = existing.appealReceipt { return receipt }
            return try await deliverAppeal(existing, to: listing)
        }

        var appeal = AppealSubmission(
            caseId: caseId,
            kind: kind,
            statement: statement
        )
        // A new-holder claim is signed too — the reference ignores the
        // signature by design, but signing costs nothing and keeps the
        // artifact self-describing if the endpoint ever authenticates.
        appeal.signature = try await signer
            .sign(appeal.signingBytes(), as: submittingUser)
            .base64EncodedString()
        let submission = CaseSubmissionRecord(
            caseId: caseId,
            mandateRef: mandateRef,
            user: submittingUser,
            authorityName: listing.name,
            kind: recordKind,
            appeal: appeal,
            createdAt: clock()
        )
        try persistNewSubmission(submission)
        return try await deliverAppeal(submission, to: listing)
    }

    /// Delivery must not begin unless the exact signed artifact is
    /// durably retained — a transport timeout may happen after the
    /// Authority committed, and only the persisted artifact lets the
    /// retry re-deliver byte-identical content.
    private func persistNewSubmission(_ submission: CaseSubmissionRecord) throws {
        caseSubmissions.insert(submission, at: 0)
        do {
            try saveCaseSubmissions()
        } catch {
            if let index = submissionIndex(of: submission) {
                caseSubmissions.remove(at: index)
            }
            throw error
        }
    }

    private func deliverResponse(
        _ submission: CaseSubmissionRecord,
        to listing: AuthorityListing
    ) async throws -> CaseResponseReceipt {
        guard let response = submission.response else {
            throw ModerationError.ledgerInconsistent("submission holds no response")
        }
        let client = authorityClients.client(for: listing)
        let receipt: CaseResponseReceipt
        do {
            receipt = try await client.respond(response)
        } catch {
            // Deterministic refusal (case already decided, filing cap,
            // anti-oracle 404) cannot become an acceptance through
            // exact replay; retaining the artifact would deadlock the
            // key. Ambiguous outcomes keep it for byte-identical retry.
            // A post-200 correlation/decoding failure is terminal too:
            // the server accepted and does not deduplicate, so a
            // "retry" would file a second row, not resolve the first.
            if isDeterministicReportRejection(error)
                || Self.isPostAcceptanceFailure(error) {
                discardSubmission(submission)
            }
            throw error
        }
        finishSubmission(submission) { $0.responseReceipt = receipt }
        return receipt
    }

    private func deliverAppeal(
        _ submission: CaseSubmissionRecord,
        to listing: AuthorityListing
    ) async throws -> AppealReceipt {
        guard let appeal = submission.appeal else {
            throw ModerationError.ledgerInconsistent("submission holds no appeal")
        }
        let client = authorityClients.client(for: listing)
        let receipt: AppealReceipt
        do {
            receipt = try await client.appeal(appeal)
        } catch {
            if isDeterministicReportRejection(error)
                || Self.isPostAcceptanceFailure(error) {
                discardSubmission(submission)
            }
            throw error
        }
        finishSubmission(submission) { $0.appealReceipt = receipt }
        return receipt
    }

    /// Record the acknowledgment. The Authority's answer is
    /// authoritative and must reach the caller; a persistence failure
    /// is logged (error only), not surfaced as a delivery failure.
    ///
    /// A row absent from the ledger stays absent: the only removal
    /// paths are deterministic discard and the identity-removal purge,
    /// and resurrecting a purged row would re-persist a removed
    /// identity's statement, defeating the purge contract. The receipt
    /// still returns to the caller.
    private func finishSubmission(
        _ submission: CaseSubmissionRecord,
        apply: (inout CaseSubmissionRecord) -> Void
    ) {
        guard let index = submissionIndex(of: submission) else { return }
        apply(&caseSubmissions[index])
        do {
            try saveCaseSubmissions()
        } catch {
            Self.logger.error("case submission persistence failed: \(error)")
        }
    }

    /// Persist the ledger, pruning acknowledged rows past the bound —
    /// and, unlike the report ledger, pending rows past their own
    /// bound: the reference does not deduplicate submissions, so a
    /// dropped pending row costs at worst a re-file the user performs
    /// knowingly, whereas unbounded pending statements (each up to
    /// 16 KB, one per edited retry while the Authority is unreachable)
    /// would grow without limit. The array is newest-first; the prune
    /// commits to memory only after the store write succeeds.
    private func saveCaseSubmissions() throws {
        var resolvedKept = 0
        var pendingKept = 0
        var droppedPending = 0
        let pruned = caseSubmissions.filter { record in
            if record.isResolved {
                resolvedKept += 1
                return resolvedKept <= Self.maxResolvedCaseSubmissions
            }
            pendingKept += 1
            if pendingKept > Self.maxPendingCaseSubmissions {
                droppedPending += 1
                return false
            }
            return true
        }
        try caseSubmissionStore.save(pruned)
        caseSubmissions = pruned
        if droppedPending > 0 {
            // Never silent: a dropped pending row means that retry
            // artifact is gone and re-filing is a fresh submission.
            Self.logger.notice(
                "case submission ledger dropped \(droppedPending) oldest pending rows past the bound"
            )
        }
    }

    private func submissionIndex(of submission: CaseSubmissionRecord) -> Int? {
        caseSubmissions.firstIndex { $0.id == submission.id }
    }

    private func discardSubmission(_ submission: CaseSubmissionRecord) {
        guard let index = submissionIndex(of: submission) else { return }
        caseSubmissions.remove(at: index)
        try? saveCaseSubmissions()
    }

    private static func validatedStatement(_ statement: String) throws -> String {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ModerationError.statementInvalid("statement is empty")
        }
        guard trimmed.utf8.count <= Self.maxStatementBytes else {
            throw ModerationError.statementInvalid(
                "statement exceeds \(Self.maxStatementBytes) bytes"
            )
        }
        return trimmed
    }

    /// Failures that can only occur AFTER the Authority answered 200:
    /// a receipt that fails caseId/kind correlation or cannot be
    /// decoded. The submission was accepted server-side, so the
    /// artifact must not be retained as retryable.
    private static func isPostAcceptanceFailure(_ error: Error) -> Bool {
        switch error {
        case AuthorityClientError.caseIdentifierMismatch,
             AuthorityClientError.malformedResponse:
            return true
        default:
            return false
        }
    }

    private static func statementHash(_ statement: String) -> String {
        SHA256.hash(data: Data(statement.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - AsyncStream

    public nonisolated var snapshots: AsyncStream<ModerationState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    private func subscribe(id: UUID, continuation: AsyncStream<ModerationState>.Continuation) {
        continuations[id] = continuation
        continuation.yield(currentState())
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func activeReportingMandate() throws -> MandateRecord {
        guard let record = activeMandateRecord(),
              record.countersigned,
              record.authorityRegistered
        else {
            throw ModerationError.reportingUnavailable(
                "no active Authority-registered mandate"
            )
        }
        return record
    }

    private func performFileReport(
        message: ReportableMessage,
        classId: String,
        reporterMandate: MandateRecord
    ) async throws -> ReportReceipt {
        let reporter = try await signer.userKeyID()
        guard reporter == reporterMandate.mandate.user else {
            throw ModerationError.reportingUnavailable(
                "active identity does not own the reporting mandate"
            )
        }
        guard let manifest = reporterMandate.consentedManifest()?.manifest,
              reporterMandate.mandate.classes.contains(classId),
              manifest.violationClasses.contains(where: { $0.classId == classId })
        else {
            throw ModerationError.classOutsideMandate(classId)
        }
        guard !message.disclosedContent.isEmpty,
              let signature = Data(base64Encoded: message.authenticityProof),
              let accusedKey = try? AuthorityKey.publicKey(fromReference: message.accused),
              accusedKey.isValidSignature(
                signature,
                for: Data(message.disclosedContent.utf8)
              )
        else {
            throw ModerationError.authenticityUnverified
        }
        guard let listing = authorities.first(where: {
            $0.componentId == reporterMandate.mandate.authority
        }) else {
            throw ModerationError.authorityUnavailable(
                reporterMandate.mandate.authority
            )
        }
        let reporterMandateRef = try reporterMandate.mandate.mandateHash()

        // The idempotency identity deliberately includes `classId` and
        // `reporterMandate`: re-reporting the same message under a
        // different violation class is a distinct allegation, and a
        // report's standing follows the mandate it was filed under
        // (spec §5.4 constraint 5) — re-consenting mints new standing,
        // with the Authority's own intake dedup as the backstop against
        // duplicate allegations over identical evidence.
        if let existing = reportRecords.first(where: {
            $0.sourceMessageId == message.id
                && $0.report.reporter == reporter
                && $0.report.reporterMandate == reporterMandateRef
                && $0.report.accused == message.accused
                && $0.report.classId == classId
                && $0.report.evidence == [EvidenceItem(
                    disclosedContent: message.disclosedContent,
                    authenticityProof: message.authenticityProof
                )]
        }) {
            if let receipt = existing.receipt { return receipt }
            if existing.resolvedWithoutReceipt == true {
                // Confirmed on file (409). Re-delivery can only 409
                // again; short-circuit to the same terminal outcome.
                throw ModerationError.reportAlreadyFiled(
                    reportId: existing.report.reportId
                )
            }
            return try await submitReport(existing, to: listing, images: message.images)
        }

        var report = Report(
            reportId: "report-\(UUID().uuidString.lowercased())",
            reporter: reporter,
            reporterMandate: reporterMandateRef,
            accused: message.accused,
            classId: classId,
            evidence: [EvidenceItem(
                disclosedContent: message.disclosedContent,
                authenticityProof: message.authenticityProof
            )],
            filedAt: clock()
        )
        report.signature = try await signer
            .sign(report.signingBytes(), as: reporter)
            .base64EncodedString()
        let record = ReportFilingRecord(
            sourceMessageId: message.id,
            report: report,
            authorityName: listing.name
        )
        reportRecords.insert(record, at: 0)
        // Delivery must not begin unless the exact signed artifact is
        // durably retained. A transport timeout may happen after intake
        // committed; without this write, a retry would mint a second report.
        do {
            try saveReportRecords()
        } catch {
            // Do not leave an unpersisted artifact eligible for the
            // in-memory exact-retry path on the next tap.
            if let index = reportIndex(of: record) {
                reportRecords.remove(at: index)
            }
            throw error
        }
        return try await submitReport(record, to: listing, images: message.images)
    }

    private func submitReport(
        _ record: ReportFilingRecord,
        to listing: AuthorityListing,
        images: [ReportableMessage.Image]
    ) async throws -> ReportReceipt {
        let client = authorityClients.client(for: listing)

        // Bytes first, then the report that names them.
        //
        // The other order would leave a filed report pointing at an
        // image the Authority does not hold — a case opened, and a mark
        // set, on evidence nobody can look at. Uploading is idempotent
        // (the digest is the address), so a retry after a partial
        // upload re-sends the same bytes rather than creating anything
        // new, and an upload that never gets referenced expires on the
        // Authority's own sweep.
        //
        // Inside the same `do` as the filing, and not before it: the
        // record is already inserted and persisted by this point, so an
        // upload failure that skipped the handling below would strand a
        // disclosure row on disk that can never be filed and re-fails
        // identically on every retry — the outcome the discard exists to
        // prevent, reached through the one call that bypassed it.
        let receipt: ReportReceipt
        do {
            for image in images {
                do {
                    try await client.uploadEvidenceImage(
                        sha256: image.sha256,
                        bytes: image.bytes
                    )
                } catch let AuthorityClientError.rejected(rejection)
                    where rejection.statusCode == 409 {
                    // The Authority already holds these exact bytes.
                    // Content addressing makes that the *expected*
                    // outcome of any retry, and there is nothing to
                    // resend. The merged reference answers 2xx here
                    // (`INSERT OR IGNORE`), but the contract does not
                    // require that, and a conflict on a
                    // content-addressed PUT can only mean agreement.
                    continue
                }
            }

            receipt = try await client.fileReport(record.report)
        } catch {
            // 409 from the filing: the Authority already holds this
            // exact report — a terminal, benign state, not a rejection.
            // (An upload conflict never reaches here; it is agreement,
            // and is absorbed above.) Keep the ledger
            // row (it is the idempotency key) and surface it as its own
            // error so the UI can present "already on file" rather than
            // retry advice. The original receipt is unrecoverable until
            // the Authority protocol grows a report-lookup endpoint.
            if case let AuthorityClientError.rejected(rejection) = error,
               rejection.statusCode == 409 {
                if let index = reportIndex(of: record) {
                    reportRecords[index].resolvedWithoutReceipt = true
                    try? saveReportRecords()
                }
                throw ModerationError.reportAlreadyFiled(
                    reportId: record.report.reportId
                )
            }
            if isDeterministicReportRejection(error) {
                discardReport(record)
            }
            throw error
        }
        // The concrete HTTP client correlates this too; repeating the
        // check here preserves the invariant for every factory-injected
        // implementation of the protocol.
        guard receipt.reportId == record.report.reportId else {
            throw AuthorityClientError.reportIdentifierMismatch(
                expected: record.report.reportId,
                received: receipt.reportId
            )
        }
        // A row absent from the ledger stays absent — the only removal
        // paths are deterministic discard and the identity-removal
        // purge, and resurrecting a purged row would re-persist a
        // removed identity's disclosure. The receipt still returns.
        if let index = reportIndex(of: record) {
            reportRecords[index].receipt = receipt
        } else {
            return receipt
        }
        do {
            try saveReportRecords()
        } catch {
            // The Authority has accepted — that outcome is authoritative
            // and must reach the user. Losing the receipt's persistence
            // is recoverable (a post-relaunch retry hits the terminal
            // already-filed path); reporting success as failure is not.
            // Error only — no report content — per no-activity-logging.
            Self.logger.error("report receipt persistence failed: \(error)")
        }
        return receipt
    }

    /// Persist the ledger, pruning resolved rows past the retention
    /// bound. Records are newest-first, so dropping from the back of
    /// the receipted subset removes the oldest disclosures first.
    private func saveReportRecords() throws {
        let resolved = reportRecords.filter(\.isResolved)
        if resolved.count > Self.maxResolvedReportRecords {
            let cutoff = Set(
                resolved.prefix(Self.maxResolvedReportRecords).map(\.report.reportId)
            )
            reportRecords.removeAll {
                $0.isResolved && !cutoff.contains($0.report.reportId)
            }
        }
        try reportStore.save(reportRecords)
    }

    /// Drop every report record not filed by one of `reporters`
    /// (`onym:key:<hex>` references). Called when an identity is
    /// removed so retained disclosures don't outlive the identity that
    /// filed them.
    public func purgeReportRecords(keepingReporters reporters: Set<String>) {
        let before = reportRecords.count
        reportRecords.removeAll { !reporters.contains($0.report.reporter) }
        guard reportRecords.count != before else { return }
        try? reportStore.save(reportRecords)
    }

    private func reportIndex(of record: ReportFilingRecord) -> Int? {
        reportRecords.firstIndex { $0.report.reportId == record.report.reportId }
    }

    private func discardReport(_ record: ReportFilingRecord) {
        guard let index = reportIndex(of: record) else { return }
        reportRecords.remove(at: index)
        try? saveReportRecords()
    }

    private func isDeterministicReportRejection(_ error: Error) -> Bool {
        guard case let AuthorityClientError.rejected(rejection) = error else {
            return false
        }
        // 409 never reaches here — `submitReport` converts it to
        // `.reportAlreadyFiled` (terminal; keeps the ledger row).
        return Self.isDeterministicStatusCode(rejection.statusCode)
    }

    /// A 4xx that exact replay can never turn into an acceptance —
    /// excluding the transient pair (408 timeout, 429 rate limit).
    private static func isDeterministicStatusCode(_ statusCode: Int) -> Bool {
        (400..<500).contains(statusCode)
            && statusCode != 408
            && statusCode != 429
    }

    /// Resume the newest interrupted consent after the directory is
    /// available. The user already signed these exact bytes; this does
    /// not create consent in the background, it only completes delivery
    /// of the persisted artifact.
    private func retryNewestPendingRegistration() async throws {
        let userKey = try await signer.userKeyID()
        guard let pending = records.first(where: {
            $0.mandate.user == userKey && $0.registrationPending
        }) else { return }

        _ = try await retryRegistration(pending)
    }

    /// Register a pending countersigned mandate and verify that the
    /// Authority derived the same content reference. Current reviewed
    /// terms become active; older terms resolved ahead of a rotation are
    /// retained as history without transiently becoming current.
    private func registerPending(
        _ pending: MandateRecord,
        with listing: AuthorityListing,
        activate: Bool
    ) async throws -> MandateRecord {
        let expectedRef = try pending.mandate.mandateHash()
        let registrationKey = RegistrationKey(
            mandateBytes: try ModerationCanonicalEncoder.encode(pending.mandate),
            createdAt: pending.createdAt
        )
        let registrationTask: Task<MandateRegistrationReceipt, Error>
        if var flight = registrationFlights[registrationKey] {
            flight.waiters += 1
            registrationFlights[registrationKey] = flight
            registrationTask = flight.task
        } else {
            let client = authorityClients.client(for: listing)
            let task = Task {
                try await client.registerMandate(pending.mandate)
            }
            registrationFlights[registrationKey] = RegistrationFlight(task: task, waiters: 1)
            registrationTask = task
        }

        let receipt: MandateRegistrationReceipt
        do {
            receipt = try await registrationTask.value
            releaseRegistrationFlight(registrationKey)
        } catch {
            releaseRegistrationFlight(registrationKey)
            // A transport failure, malformed reply, or 5xx may happen
            // after the Authority committed, so those retain the exact
            // artifact for retry. A definitive artifact failure cannot
            // become valid through exact replay and must not deadlock
            // every future consent attempt.
            if isDeterministicRegistrationRejection(error) {
                discardRegistrationAttempt(pending)
            }
            throw error
        }
        // The concrete HTTP client validates these too. Repeating the
        // checks here preserves the invariant for every factory-injected
        // implementation of the protocol.
        guard receipt.mandateRef == expectedRef else {
            discardRegistrationAttempt(pending)
            throw AuthorityClientError.mandateReferenceMismatch(
                expected: expectedRef,
                received: receipt.mandateRef
            )
        }
        guard receipt.accepted else {
            discardRegistrationAttempt(pending)
            throw AuthorityClientError.mandateNotAccepted(mandateRef: receipt.mandateRef)
        }

        // The content reference excludes signatures. Locate the exact
        // persisted record instead, then activate only that array entry;
        // two records with the same unsigned fields must never both become
        // active merely because they share a content hash.
        guard let pendingIndex = recordIndex(of: pending) else {
            // Defensive recovery for a future mutation path: the
            // Authority has accepted these exact bytes, so reconstruct
            // the local registered record rather than minting again.
            var recovered = pending
            recovered.authorityRegistered = true
            recovered.isActive = activate
            if activate {
                for index in records.indices {
                    records[index].isActive = false
                }
            }
            records.insert(recovered, at: 0)
            mandateStore.save(records)
            publish()
            return recovered
        }
        let wasPending = records[pendingIndex].registrationPending
        if activate {
            for index in records.indices {
                records[index].isActive = index == pendingIndex
            }
        } else if wasPending {
            // Do not let a second waiter with `activate == false`
            // deactivate a record an explicit-consent waiter has just
            // activated from the same shared registration response.
            records[pendingIndex].isActive = false
        }
        records[pendingIndex].authorityRegistered = true
        let activated = records[pendingIndex]
        mandateStore.save(records)
        publish()
        return activated
    }

    private func releaseRegistrationFlight(_ key: RegistrationKey) {
        guard var flight = registrationFlights[key] else { return }
        flight.waiters -= 1
        if flight.waiters == 0 {
            registrationFlights.removeValue(forKey: key)
        } else {
            registrationFlights[key] = flight
        }
    }

    /// Records are newest-first. Dates make the ordering explicit; the
    /// array position breaks ties for stores written under a fixed or
    /// low-resolution clock. Any later completed consent prevents this
    /// background retry from rolling the user's selection backward.
    private func shouldActivateResolvedPending(_ pending: MandateRecord) -> Bool {
        guard let pendingIndex = recordIndex(of: pending) else { return false }
        return !records.enumerated().contains { index, record in
            guard record.mandate.user == pending.mandate.user,
                  !record.registrationPending
            else { return false }
            return record.createdAt > pending.createdAt
                || (record.createdAt == pending.createdAt && index < pendingIndex)
        }
    }

    private func recordIndex(of record: MandateRecord) -> Int? {
        records.firstIndex(where: {
            $0.mandate == record.mandate
                && $0.manifestBytes == record.manifestBytes
                && $0.authorityName == record.authorityName
                && $0.countersigned == record.countersigned
                && $0.createdAt == record.createdAt
        })
    }

    private func discardRegistrationAttempt(_ record: MandateRecord) {
        guard let index = recordIndex(of: record) else { return }
        records.remove(at: index)
        mandateStore.save(records)
        publish()
    }

    private func isDeterministicRegistrationRejection(_ error: Error) -> Bool {
        guard let error = error as? AuthorityClientError else { return false }
        switch error {
        case .mandateNotAccepted, .mandateReferenceMismatch:
            return true
        case .rejected(let rejection):
            return Self.isDeterministicStatusCode(rejection.statusCode)
        case .invalidResponse, .malformedResponse, .invalidPathComponent, .insecureBaseURL,
             .reportIdentifierMismatch, .caseIdentifierMismatch:
            return false
        }
    }

    private func publish() {
        let state = currentState()
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }
}
