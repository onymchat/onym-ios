import Foundation

/// Drives one backup: compose, preflight, upload, record.
///
/// The state machine is small and its edges are the interesting part —
/// what it refuses to do is most of the design.
public actor BackupRepository {
    private let port: any BackupPort
    private let composer: BackupComposer
    private let stateStore: any BackupStateStoring
    private let keyMaterial: BackupKeyMaterial

    public init(
        port: any BackupPort,
        composer: BackupComposer,
        stateStore: any BackupStateStoring,
        keyMaterial: BackupKeyMaterial
    ) {
        self.port = port
        self.composer = composer
        self.stateStore = stateStore
        self.keyMaterial = keyMaterial
    }

    /// What a caller sees after asking for a backup.
    public enum RunResult: Sendable, Equatable {
        case retained(SnapshotReference)
        case alreadyRetained(SnapshotReference)
        /// The operator wants payment. The sealed bytes are kept so the
        /// retry after purchase sends the *same* snapshot.
        case paymentRequired(componentId: String, offerIds: [String], pending: SealedSnapshot)
        /// Terms moved. Uploading would pin something nobody agreed to.
        case termsChanged(currentTermsId: String?)
        /// The request went out and we never learned what happened.
        case unknown(operationId: String)
    }

    /// Compose a fresh snapshot and try to place it.
    public func backUp(now: Date = Date()) async throws -> RunResult {
        var state = try stateStore.load()

        // Reconcile before adding to the pile. An operation whose result
        // we never learned may well have succeeded, and composing a
        // second snapshot on top of an unresolved first is how a person
        // ends up paying to store the same history twice.
        try await reconcile(&state)

        guard let acceptedTermsId = state.acceptedTermsId else {
            // Nothing has been consented to. Enrolment is a decision, and
            // the repository does not make it on the person's behalf.
            throw BackupError.termsUnavailable
        }

        let connection = try await port.connect()
        if connection.acceptedTermsId != acceptedTermsId {
            // Do not upload, do not re-pin, do not "helpfully" accept.
            // Fresh consent is a screen, not an inference.
            state.lastAttemptAt = now
            try stateStore.save(state)
            return .termsChanged(currentTermsId: connection.acceptedTermsId)
        }

        let snapshot = try await composer.compose(
            keyMaterial: keyMaterial,
            acceptedTermsId: acceptedTermsId,
            supersedes: state.snapshots.last.map {
                try? SnapshotReference(digest: $0.digest, sealedByteSize: $0.sealedByteSize)
            } ?? nil,
            now: now
        )
        state.lastAttemptAt = now
        try stateStore.save(state)
        return try await place(snapshot, state: &state, now: now)
    }

    /// Retry a snapshot that was refused for payment, byte for byte.
    ///
    /// Takes the `SealedSnapshot` the refusal handed back rather than
    /// composing again: a fresh composition mints a new salt and a new
    /// digest, which would defeat both the retry and `already_retained`,
    /// and would charge the person for a second copy of the same
    /// history.
    public func retry(_ snapshot: SealedSnapshot, now: Date = Date()) async throws -> RunResult {
        var state = try stateStore.load()
        return try await place(snapshot, state: &state, now: now)
    }

    private func place(
        _ snapshot: SealedSnapshot,
        state: inout BackupState,
        now: Date
    ) async throws -> RunResult {
        let preflight: BackupPreflight
        do {
            preflight = try await port.preflight(snapshot)
        } catch let error as BackupError {
            switch error {
            case .paymentRequired(let componentId, let offerIds, _):
                // The sealed bytes stay on disk. Nothing is discarded
                // for a refusal that a purchase resolves.
                return .paymentRequired(
                    componentId: componentId, offerIds: offerIds, pending: snapshot)
            case .termsChanged(let currentTermsId):
                return .termsChanged(currentTermsId: currentTermsId)
            default:
                throw error
            }
        }

        switch preflight {
        case .alreadyRetained(let outcome):
            try discard(snapshot)
            state.lastSuccessAt = now
            try stateStore.save(state)
            return .alreadyRetained(outcome.snapshotReference ?? snapshot.snapshotReference)

        case .granted(let grant):
            // Recorded *before* the upload, not after. If the response
            // is lost we must still know an operation is outstanding —
            // a record written only on success is exactly the record
            // that is missing when it matters.
            state.pendingOperations.append(
                BackupState.PendingOperation(
                    operationId: snapshot.operationId,
                    digest: snapshot.snapshotReference.digest,
                    startedAt: now
                )
            )
            try stateStore.save(state)

            let outcome: BackupOutcome
            do {
                outcome = try await port.uploadSnapshot(snapshot, grant: grant)
            } catch {
                // Preserved as unresolved rather than reported as
                // failure: the bytes may well be held, and only the
                // operator can say.
                return .unknown(operationId: snapshot.operationId)
            }

            state.pendingOperations.removeAll { $0.operationId == snapshot.operationId }
            guard outcome.status.isRetention else {
                // `submitted` and `accepted` are not retention. Recording
                // either as success is the lie this vocabulary exists to
                // prevent.
                try stateStore.save(state)
                return .unknown(operationId: snapshot.operationId)
            }

            state.snapshots.append(
                BackupState.RecordedSnapshot(
                    digest: snapshot.snapshotReference.digest,
                    sealedByteSize: snapshot.snapshotReference.sealedByteSize,
                    acceptedTermsId: snapshot.acceptedTermsId,
                    uploadedAt: now,
                    statusRaw: outcome.status.rawValue
                )
            )
            state.lastSuccessAt = now
            try stateStore.save(state)
            try discard(snapshot)
            return .retained(snapshot.snapshotReference)
        }
    }

    /// Ask the operator about operations we lost track of.
    private func reconcile(_ state: inout BackupState) async throws {
        guard !state.pendingOperations.isEmpty else { return }
        var stillPending: [BackupState.PendingOperation] = []
        for pending in state.pendingOperations {
            guard let outcome = try? await port.queryOutcome(operationId: pending.operationId) else {
                // No answer, or no record. It stays pending: an
                // operation we cannot resolve is not an operation that
                // failed, and dropping it here would quietly convert
                // uncertainty into a clean slate.
                stillPending.append(pending)
                continue
            }
            if outcome.status.isRetention,
               let reference = outcome.snapshotReference {
                state.snapshots.append(
                    BackupState.RecordedSnapshot(
                        digest: reference.digest,
                        sealedByteSize: reference.sealedByteSize,
                        acceptedTermsId: state.acceptedTermsId ?? "",
                        uploadedAt: pending.startedAt,
                        statusRaw: outcome.status.rawValue
                    )
                )
            } else if outcome.status == .unknown || outcome.status == .unreachable {
                stillPending.append(pending)
            }
        }
        state.pendingOperations = stillPending
        try stateStore.save(state)
    }

    /// Remove sealed bytes once they are no longer needed. Failing to
    /// delete is not worth failing a completed backup over; the working
    /// directory is swept on the next run.
    private func discard(_ snapshot: SealedSnapshot) throws {
        try? FileManager.default.removeItem(at: snapshot.sealedBytesURL)
    }
}
