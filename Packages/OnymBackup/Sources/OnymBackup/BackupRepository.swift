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

    /// Set while a run is in flight.
    ///
    /// Actor reentrancy is real: `backUp` loads state at entry and saves
    /// across many `await port.*` suspension points, so two interleaved
    /// runs would each save their own stale copy — and the one that lost
    /// would take the other's just-written pending record with it. That
    /// record is the entire uncertainty design, so runs are serialized
    /// rather than merged.
    private var isRunning = false

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
        /// A different operator is now consented to than the one this
        /// state was enrolled with. Nothing may be uploaded, reconciled
        /// or retried until the person has enrolled with the new one —
        /// none of the recorded work means anything to it.
        case operatorChanged(previousComponentId: String, currentComponentId: String)
        /// The request went out and we never learned what happened.
        case unknown(operationId: String)
        /// Earlier work is unresolved and could not be reconciled, so
        /// nothing new was composed.
        case awaitingReconciliation(operationIds: [String])
        /// Another run is already in flight.
        case alreadyRunning
    }

    /// Compose a fresh snapshot and try to place it.
    public func backUp(now: Date = Date()) async throws -> RunResult {
        guard !isRunning else { return .alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        var state = try stateStore.load()

        guard let acceptedTermsId = state.acceptedTermsId else {
            // Nothing has been consented to. Enrolment is a decision, and
            // the repository does not make it on the person's behalf.
            throw BackupError.termsUnavailable
        }

        // Terms and operator are checked *before* reconciling, not after.
        //
        // Reconciliation talks to whichever operator this repository was
        // built for, using operation ids recorded against whoever was
        // consented to when they were written. If those are not the same
        // operator, reconciling first hands operator B a list of operator
        // A's operations — the cross-operator leak the rebind on
        // enrolment exists to prevent, arrived at through a different
        // door.
        // Do not upload, do not re-pin, do not "helpfully" accept.
        // Fresh consent is a screen, not an inference.
        if let mismatch = try await operatorOrTermsMismatch(state: state, now: now) {
            state.lastAttemptAt = now
            try stateStore.save(state)
            return mismatch
        }
        _ = acceptedTermsId

        // Only now: an operation whose result we never learned may well
        // have succeeded, and composing a second snapshot on top of an
        // unresolved first is how a person ends up paying to store the
        // same history twice.
        try await reconcile(&state)

        // And if it is *still* unresolved, do not compose. Reconciling
        // first only prevents double storage if failing to reconcile
        // also stops us — otherwise a run that cannot reach the operator
        // mints a fresh salt and digest every time, and the operator
        // retains each one beside the copy we lost track of. The caller
        // is told, so a UI can say "checking on an earlier backup"
        // rather than showing a silent no-op.
        guard state.pendingOperations.isEmpty else {
            state.lastAttemptAt = now
            try stateStore.save(state)
            return .awaitingReconciliation(
                operationIds: state.pendingOperations.map(\.operationId))
        }

        let snapshot = try await composer.compose(
            keyMaterial: keyMaterial,
            acceptedTermsId: acceptedTermsId,
            supersedes: try state.newestSnapshot.map {
                // `try?` here would turn an unreadable ancestor into a
                // snapshot claiming to supersede nothing, quietly
                // breaking the chain. The store refuses to *read*
                // corrupt state for the same reason; it should not be
                // written past here either.
                do {
                    return try SnapshotReference(
                        digest: $0.digest, sealedByteSize: $0.sealedByteSize)
                } catch {
                    throw BackupError.localFailure(reason: .stateUnreadable)
                }
            },
            now: now
        )
        state.lastAttemptAt = now
        try stateStore.save(state)
        return try await place(snapshot, state: &state, now: now)
    }

    /// The snapshot waiting on a purchase, if one survived a relaunch.
    ///
    /// Returns `nil` when the recorded sealed bytes are gone — there is
    /// nothing to retry, and reporting a pending payment we cannot honour
    /// would strand the caller in a purchase flow with no snapshot at the
    /// end of it.
    public func pendingPayment(in workingDirectory: URL? = nil) throws -> SealedSnapshot? {
        var state = try stateStore.load()
        guard let pending = state.awaitingPayment else { return nil }
        let url = (workingDirectory ?? composer.workingDirectory)
            .appending(path: pending.sealedBytesFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // The bytes are gone, so there is nothing to retry — and the
            // record has to go with them. Leaving it would strand the
            // settings screen on "Payment needed" forever, including
            // after later backups succeed, for a purchase that can no
            // longer buy anything.
            state.awaitingPayment = nil
            try stateStore.save(state)
            return nil
        }
        return SealedSnapshot(
            operationId: pending.operationId,
            snapshotReference: try SnapshotReference(
                digest: pending.digest, sealedByteSize: pending.sealedByteSize),
            sealedBytesURL: url,
            sealedAt: pending.sealedAt,
            acceptedTermsId: pending.acceptedTermsId,
            supersedes: try pending.supersedesDigest.flatMap { digest in
                try pending.supersedesByteSize.map {
                    try SnapshotReference(digest: digest, sealedByteSize: $0)
                }
            }
        )
    }

    /// Retry a snapshot that was refused for payment, byte for byte.
    ///
    /// Takes the `SealedSnapshot` the refusal handed back rather than
    /// composing again: a fresh composition mints a new salt and a new
    /// digest, which would defeat both the retry and `already_retained`,
    /// and would charge the person for a second copy of the same
    /// history.
    public func retry(_ snapshot: SealedSnapshot, now: Date = Date()) async throws -> RunResult {
        guard !isRunning else { return .alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        var state = try stateStore.load()
        // The same preconditions `backUp` checks, for the same reason —
        // more so here. This snapshot was sealed under one operator's
        // terms and pinned to its digest; sending it to a different
        // operator is the leak this whole seam exists to close, and the
        // retry path is the shortest route to it.
        if let mismatch = try await operatorOrTermsMismatch(state: state, now: now) {
            return mismatch
        }
        // And the snapshot's own pin must match what we are enrolled
        // under. A snapshot left over from earlier terms is not one to
        // send now.
        guard snapshot.acceptedTermsId == state.acceptedTermsId else {
            return .termsChanged(currentTermsId: state.acceptedTermsId)
        }
        return try await place(snapshot, state: &state, now: now)
    }

    /// Save, unless someone re-enrolled underneath us.
    ///
    /// Enrolment runs on the main actor and rewrites this file; a run
    /// here loads at the start and saves across several network hops.
    /// An upload finishing after a re-enrolment would otherwise write
    /// back its stale copy — resurrecting the previous operator's
    /// `componentId` and pending operations, and silently undoing the
    /// rebind that was the whole point.
    ///
    /// So the write is conditional on the enrolment not having moved.
    /// Losing our own bookkeeping is the right side to fail on: the
    /// snapshot itself is either retained or not regardless, and the
    /// next run reconciles against the operator rather than trusting
    /// this file.
    @discardableResult
    private func commit(_ state: BackupState, expecting enrolled: String?) throws -> Bool {
        let current = try stateStore.load()
        guard current.componentId == enrolled, current.acceptedTermsId == state.acceptedTermsId
        else {
            return false
        }
        try stateStore.save(state)
        return true
    }

    /// Shared precondition: are we still talking to the operator this
    /// state was enrolled with, under the terms it pinned?
    ///
    /// Returns the result to hand back, or `nil` to proceed.
    private func operatorOrTermsMismatch(
        state: BackupState,
        now: Date
    ) async throws -> RunResult? {
        let connection = try await port.connect()
        // `componentId` is nil for state written before it was recorded.
        // That is not "matches" — we cannot tell, and guessing in favour
        // of proceeding is how a snapshot reaches the wrong operator. It
        // is treated as a switch, which routes to enrolment.
        guard let enrolled = state.componentId else {
            return .operatorChanged(
                previousComponentId: "",
                currentComponentId: connection.manifest.componentId)
        }
        if enrolled != connection.manifest.componentId {
            return .operatorChanged(
                previousComponentId: enrolled,
                currentComponentId: connection.manifest.componentId)
        }
        if connection.acceptedTermsId != state.acceptedTermsId {
            return .termsChanged(currentTermsId: connection.acceptedTermsId)
        }
        return nil
    }

    private func place(
        _ snapshot: SealedSnapshot,
        state: inout BackupState,
        now: Date
    ) async throws -> RunResult {
        // What we were enrolled with when this run began. Every write
        // below is conditional on it still being true.
        let enrolled = state.componentId
        let preflight: BackupPreflight
        do {
            preflight = try await port.preflight(snapshot)
        } catch let error as BackupError {
            switch error {
            case .paymentRequired(let componentId, let offerIds, _):
                // The sealed bytes stay on disk *and* the fact that they
                // are owed a purchase is written down. A StoreKit
                // purchase routinely resolves after a relaunch, and a
                // snapshot remembered only in a returned enum would be
                // swept as scratch — re-composed, re-salted, and paid
                // for twice.
                state.awaitingPayment = BackupState.PendingPayment(
                    operationId: snapshot.operationId,
                    digest: snapshot.snapshotReference.digest,
                    sealedByteSize: snapshot.snapshotReference.sealedByteSize,
                    sealedBytesFilename: snapshot.sealedBytesURL.lastPathComponent,
                    acceptedTermsId: snapshot.acceptedTermsId,
                    supersedesDigest: snapshot.supersedes?.digest,
                    supersedesByteSize: snapshot.supersedes?.sealedByteSize,
                    sealedAt: snapshot.sealedAt,
                    refusedAt: now
                )
                try commit(state, expecting: enrolled)
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
            // An echoed reference that is not the one we asked about is
            // an operator answering a different question. Recording it
            // would let a counterparty choose what the next run
            // supersedes.
            if let echoed = outcome.snapshotReference,
               echoed.digest != snapshot.snapshotReference.digest {
                throw BackupError.rejected(
                    code: "reference_mismatch",
                    message: "the operator answered about a different snapshot"
                )
            }
            let reference = snapshot.snapshotReference
            // Recorded like any other retention. Skipping it would leave
            // the next run's `supersedes` pointing at a stale ancestor —
            // the operator holds this snapshot, whoever put it there.
            state.record(
                reference: reference,
                acceptedTermsId: snapshot.acceptedTermsId,
                at: now,
                status: outcome.status
            )
            state.lastSuccessAt = now
            state.clearPendingPayment(for: snapshot.operationId)
            try commit(state, expecting: enrolled)
            discard(snapshot)
            return .alreadyRetained(reference)

        case .granted(let grant):
            // Recorded *before* the upload, not after. If the response
            // is lost we must still know an operation is outstanding —
            // a record written only on success is exactly the record
            // that is missing when it matters.
            state.pendingOperations.append(
                BackupState.PendingOperation(
                    operationId: snapshot.operationId,
                    digest: snapshot.snapshotReference.digest,
                    sealedByteSize: snapshot.snapshotReference.sealedByteSize,
                    startedAt: now,
                    acceptedTermsId: snapshot.acceptedTermsId
                )
            )
            try commit(state, expecting: enrolled)

            let outcome: BackupOutcome
            do {
                outcome = try await port.uploadSnapshot(snapshot, grant: grant)
            } catch {
                // Preserved as unresolved rather than reported as
                // failure: the bytes may well be held, and only the
                // operator can say.
                return .unknown(operationId: snapshot.operationId)
            }

            guard outcome.status.isRetention else {
                // `submitted` and `accepted` are not retention, and the
                // pending record stays. Clearing it here would drop the
                // uncertainty on the floor — reconcile would never
                // re-query, and "silence is not success" would hold only
                // until the next line of code.
                try commit(state, expecting: enrolled)
                return .unknown(operationId: snapshot.operationId)
            }
            state.pendingOperations.removeAll { $0.operationId == snapshot.operationId }

            state.record(
                reference: snapshot.snapshotReference,
                acceptedTermsId: snapshot.acceptedTermsId,
                at: now,
                status: outcome.status
            )
            state.lastSuccessAt = now
            state.clearPendingPayment(for: snapshot.operationId)
            try commit(state, expecting: enrolled)
            discard(snapshot)
            return .retained(snapshot.snapshotReference)
        }
    }

    /// Resolve operations we lost track of.
    ///
    /// Two sources, in order of authority. `listSnapshots` says what is
    /// *retained*, which is the question actually being asked;
    /// `queryOutcome` says what happened to one operation, and an
    /// operator only keeps those for a declared window measured in hours
    /// (§15 of the profile). Querying alone would therefore leave any
    /// response lost for longer than that window pending forever,
    /// re-asked on every run for the life of the install.
    ///
    /// So: if the digest is in the retained list, it is retained. If the
    /// list came back and the digest is not in it, the upload did not
    /// result in retention and the record is resolved — negatively, but
    /// resolved. Only a list we could not fetch leaves things pending,
    /// because that is the one case where we genuinely do not know.
    private func reconcile(_ state: inout BackupState) async throws {
        guard !state.pendingOperations.isEmpty else { return }
        let enrolled = state.componentId

        guard let retained = try? await port.listSnapshots() else {
            // No list, no conclusions. Uncertainty survives a failed
            // reconciliation rather than being resolved by it.
            return
        }
        let retainedByDigest = Dictionary(
            retained.map { ($0.snapshotReference.digest, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var stillPending: [BackupState.PendingOperation] = []
        for pending in state.pendingOperations {
            if let row = retainedByDigest[pending.digest] {
                // Our own pin, not the operator's echo. Which terms a
                // stored snapshot was accepted under is not a fact a
                // counterparty gets to restate — and an empty pin is not
                // something this type writes.
                guard let pinnedTerms = pending.acceptedTermsId ?? state.acceptedTermsId,
                      !pinnedTerms.isEmpty
                else {
                    stillPending.append(pending)
                    continue
                }
                state.record(
                    reference: row.snapshotReference,
                    acceptedTermsId: pinnedTerms,
                    at: pending.startedAt,
                    status: .retained
                )
                resolve(pending, in: &state)
                continue
            }

            // Not in the list yet. That is not the same as never having
            // happened: an upload can be accepted and still in flight.
            let outcome: BackupOutcome?
            do {
                outcome = try await port.queryOutcome(operationId: pending.operationId)
            } catch {
                // Could not ask. A failed query resolves nothing — the
                // same rule as a failed list, and for the same reason.
                stillPending.append(pending)
                continue
            }

            guard let outcome else {
                // The operator answered and has no record. Combined with
                // its absence from the retained list, the upload did not
                // result in retention.
                resolve(pending, in: &state, retained: false)
                continue
            }
            switch outcome.status {
            case .retained, .alreadyRetained:
                // Not in the list but claimed retained. Believe the
                // digest and the size *we* recorded, never the ones
                // echoed back — and if we cannot rebuild the reference
                // from our own record, keep the operation pending rather
                // than throwing.
                //
                // Throwing here wedged everything: reconcile ran before
                // composing, so a single unbuildable reference aborted
                // `backUp` before it could save, leaving the operation
                // unresolved and every subsequent run to hit the same
                // line. A terse — or hostile — operator could brick
                // backups permanently with a *success* answer.
                guard
                    let size = pending.sealedByteSize ?? outcome.snapshotReference?.sealedByteSize,
                    let reference = try? SnapshotReference(digest: pending.digest, sealedByteSize: size),
                    let pinnedTerms = pending.acceptedTermsId ?? state.acceptedTermsId,
                    !pinnedTerms.isEmpty
                else {
                    // An empty terms pin is exactly what the rest of this
                    // type refuses to write.
                    stillPending.append(pending)
                    continue
                }
                state.record(
                    reference: reference,
                    acceptedTermsId: pinnedTerms,
                    at: pending.startedAt,
                    status: .retained
                )
                resolve(pending, in: &state)
            case .rejected:
                // Refused, definitively. Resolved — including any
                // purchase it was waiting on, which buys nothing now.
                resolve(pending, in: &state, retained: false)
                continue
            default:
                // queuedLocally, submitted, accepted, unknown,
                // unreachable — all still in flight. Resolving these
                // negatively would compose a second snapshot on top of
                // one the operator is still working on, and charge for
                // both.
                stillPending.append(pending)
            }
        }
        state.pendingOperations = stillPending
        try commit(state, expecting: enrolled)
    }

    /// What the operator says it holds for this holder.
    ///
    /// The operator's list is authoritative about retention; the local
    /// chain records what *we* did. They can differ — a snapshot
    /// uploaded from another device, or one whose response we lost — and
    /// a surface showing "your backups" should show the operator's
    /// answer rather than our memory of it.
    public func listSnapshots() async throws -> [RetainedSnapshot] {
        try await port.listSnapshots()
    }

    /// Erase, and record the receipt.
    ///
    /// The receipt is kept because its `excludedScope` outlives the
    /// snapshot it describes: what an erasure did not reach is the part
    /// a person may need to re-read long afterwards.
    @discardableResult
    public func erase(scope: ErasureScope) async throws -> ErasureReceipt {
        let receipt = try await port.eraseSnapshot(scope: scope)
        var state = try stateStore.load()
        let enrolled = state.componentId
        state.receipts.append(receipt.rawBytes)
        if case .snapshot(let reference) = scope {
            state.snapshots.removeAll { $0.digest == reference.digest }
        } else {
            state.snapshots.removeAll()
        }
        try commit(state, expecting: enrolled)
        return receipt
    }

    /// Export every retained snapshot in portable form.
    ///
    /// Never gated on payment here, and it must not be gated at the
    /// operator either — retention is not leverage over someone's own
    /// history.
    public func export(to directory: URL) async throws -> BackupExport {
        try await port.exportSnapshots(to: directory)
    }

    /// Close out a pending operation: clear any purchase it was waiting
    /// on, drop its sealed bytes, and — when it landed — record that a
    /// backup succeeded.
    ///
    /// Without the first part, `pendingPayment(in:)` keeps reporting a
    /// purchase owed for a snapshot the operator already holds, which is
    /// precisely the stranding its own doc comment warns about.
    private func resolve(
        _ pending: BackupState.PendingOperation,
        in state: inout BackupState,
        retained: Bool = true
    ) {
        if let payment = state.awaitingPayment, payment.operationId == pending.operationId {
            discardSealedBytes(named: payment.sealedBytesFilename)
            state.awaitingPayment = nil
        }
        if retained {
            // A backup that landed is a backup that landed, whichever
            // run found out about it.
            state.lastSuccessAt = max(state.lastSuccessAt ?? pending.startedAt, pending.startedAt)
        }
    }

    /// Remove sealed bytes once they are no longer needed.
    ///
    /// Not throwing: failing to delete is not worth failing a completed
    /// backup over, and the working directory is swept on the next run.
    private func discard(_ snapshot: SealedSnapshot) {
        try? FileManager.default.removeItem(at: snapshot.sealedBytesURL)
    }

    private func discardSealedBytes(named filename: String) {
        try? FileManager.default.removeItem(
            at: composer.workingDirectory.appending(path: filename))
    }
}
