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

/// Owns authority designation + mandate lifecycle: fetches the
/// directory, verifies and pins manifests, signs mandates, and keeps
/// exactly one record active per device. `consent(to:)` is one path
/// for both onboarding and switching — swapping authorities *is*
/// signing a fresh mandate (Moderation.md §5.3).
public actor ModerationRepository {
    /// This interface's component id, carried in every mandate.
    public static let interfaceComponentId = "onym:component:onym-ios"

    private let authoritiesFetcher: any KnownAuthoritiesFetcher
    private let manifestFetcher: any AuthorityManifestFetcher
    private let manifestValidator: AuthorityManifestValidator
    private let mandateStore: any MandateStore
    private let backend: any EnforcementBackendClient
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

    /// Consent to `listing`: fetch + verify + validate + pin its
    /// manifest, enroll this device, sign the mandate, obtain the
    /// interface countersignature, persist. Any previously active record is
    /// deactivated untouched — its mandate stays bound to the manifest
    /// hash it consented to, forever.
    @discardableResult
    public func consent(to listing: AuthorityListing) async throws -> MandateRecord {
        let signedManifest = try await manifestFetcher.fetch(listing)

        // Validity conditions (validUntil, supported profile, external
        // appellate for permanent classes) gate enrollment and signing —
        // not just the consent UI. An invalid manifest must never end up
        // pinned by a signed mandate.
        try manifestValidator.validateForConsent(signedManifest, now: clock())

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
        let userKey = try await signer.userKeyID()
        let enrollmentSignature = try await signer.sign(
            GateCheckRequest.signedPayload(deviceToken: token, timestamp: clock())
        )
        let enrollment = try await backend.enrollDevice(
            token: token,
            userKey: userKey,
            signature: enrollmentSignature
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

        let countersigned = try await backend.countersignMandate(mandate)
        let isCountersigned = countersigned.signatures.count > 1
            && countersigned.signatures.last != StubEnforcementBackendClient.countersignSentinel

        let record = MandateRecord(
            mandate: countersigned,
            manifestBytes: signedManifest.rawBytes,
            authorityName: listing.name,
            countersigned: isCountersigned,
            isActive: true,
            createdAt: clock()
        )

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

    private func publish() {
        let state = currentState()
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }
}
