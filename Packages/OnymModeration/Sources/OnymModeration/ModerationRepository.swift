import Foundation

/// Outcome of the most recent authorities-directory fetch. Same
/// shape as `RelayerFetchStatus` so the picker copy stays consistent.
public enum AuthorityFetchStatus: Equatable, Sendable {
    case idle
    case fetching
    case success
    case failed(message: String)
}

/// Combined snapshot for consent and settings UI: the designated
/// authorities, the fetch state of that list, and the mandate
/// history for this device.
public struct ModerationState: Sendable, Equatable {
    public let authorities: [AuthorityListing]
    public let fetchStatus: AuthorityFetchStatus
    /// The active record, if the user has consented.
    public let activeMandate: MandateRecord?
    /// Every record ever signed on this device, newest first —
    /// old mandates stay pinned to their consented manifest hashes.
    public let history: [MandateRecord]

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
        history: [MandateRecord]
    ) {
        self.authorities = authorities
        self.fetchStatus = fetchStatus
        self.activeMandate = activeMandate
        self.history = history
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

    private let authoritiesFetcher: any KnownAuthoritiesFetcher
    private let manifestFetcher: any AuthorityManifestFetcher
    private let manifestValidator: AuthorityManifestValidator
    private let mandateStore: any MandateStore
    private let backend: any EnforcementBackendClient
    private let authorityClients: any ModerationAuthorityClientFactory
    private let attestation: any DeviceAttestationProvider
    private let signer: any ModerationSigner
    private let clock: @Sendable () -> Date

    private var authorities: [AuthorityListing] = []
    private var fetchStatus: AuthorityFetchStatus = .idle
    private var records: [MandateRecord]
    private var continuations: [UUID: AsyncStream<ModerationState>.Continuation] = [:]
    private var startTask: Task<Void, Never>?

    public init(
        authoritiesFetcher: any KnownAuthoritiesFetcher,
        manifestFetcher: any AuthorityManifestFetcher,
        mandateStore: any MandateStore,
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
        self.backend = backend
        self.authorityClients = authorityClients
        self.attestation = attestation
        self.signer = signer
        self.clock = clock
        self.records = mandateStore.load()
    }

    // MARK: - Directory refresh

    /// Background refresh of the designated-authorities list.
    /// Idempotent; failures leave the (empty or previous) list alone.
    public func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            try? await self?.refresh()
        }
    }

    /// Fetch the latest directory. Throws so consent UI can surface
    /// failure with a retry affordance.
    public func refresh() async throws {
        fetchStatus = .fetching
        publish()
        do {
            authorities = try await authoritiesFetcher.fetchLatest()
            fetchStatus = .success
        } catch {
            fetchStatus = .failed(message: String(localized: "Couldn't load the authority list."))
            publish()
            throw error
        }
        publish()
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
        let userKey = try await signer.userKeyID()

        // If registration previously failed after countersigning, retry
        // that immutable mandate byte-for-byte. Minting a replacement
        // would leave two consent artifacts at an Authority that may
        // have accepted the first request before its response was lost.
        if let pending = records.first(where: {
            $0.mandate.authority == listing.componentId
                && $0.mandate.user == userKey
                && $0.mandate.manifestHash == signedManifest.manifestHash
                && $0.countersigned
                && !$0.authorityRegistered
        }) {
            return try await registerAndActivate(pending, with: listing)
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
        let isCountersigned = countersignature.signature
            != StubEnforcementBackendClient.countersignSentinel
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
            return try await registerAndActivate(record, with: listing)
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
        publish()
        return record
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
            history: records
        )
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

    /// Register a pending countersigned mandate, verify that the
    /// Authority derived the same content reference, then atomically
    /// make it the locally active record.
    private func registerAndActivate(
        _ pending: MandateRecord,
        with listing: AuthorityListing
    ) async throws -> MandateRecord {
        let expectedRef = try pending.mandate.mandateHash()
        let client = authorityClients.client(for: listing)
        let receipt = try await client.registerMandate(pending.mandate)
        guard receipt.accepted else {
            throw AuthorityClientError.mandateNotAccepted(mandateRef: receipt.mandateRef)
        }
        guard receipt.mandateRef == expectedRef else {
            throw AuthorityClientError.mandateReferenceMismatch(
                expected: expectedRef,
                received: receipt.mandateRef
            )
        }

        // The content reference excludes signatures. Locate the exact
        // persisted record instead, then activate only that array entry;
        // two records with the same unsigned fields must never both become
        // active merely because they share a content hash.
        guard let pendingIndex = records.firstIndex(where: {
            $0.mandate == pending.mandate
                && $0.manifestBytes == pending.manifestBytes
                && $0.authorityName == pending.authorityName
                && $0.countersigned == pending.countersigned
                && $0.createdAt == pending.createdAt
        }) else {
            throw AuthorityClientError.malformedResponse(
                "registered mandate disappeared from the local store"
            )
        }
        for index in records.indices {
            records[index].isActive = index == pendingIndex
        }
        records[pendingIndex].authorityRegistered = true
        let activated = records[pendingIndex]
        mandateStore.save(records)
        publish()
        return activated
    }

    private func publish() {
        let state = currentState()
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }
}
