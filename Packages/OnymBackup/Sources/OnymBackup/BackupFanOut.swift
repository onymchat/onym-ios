import CryptoKit
import Foundation

/// Keeps one history with several operators at once.
///
/// The reason this exists rather than a loop at the call site is that the
/// expensive half of a backup is shared and the cheap half is not. The
/// history is read once; the seal, the terms pin, the chain position, the
/// operation id, the payment and the reconciliation are all per operator
/// and none of them may be borrowed from a neighbour
/// (`UI-Backup.md` §14.12: one operator never receives another's
/// entitlement, token, access proof, or authorization).
///
/// What a person gets out of it is the thing a single operator cannot
/// give them: an operator can shut down, be seized, lose a region, or
/// decide it no longer wants their business, and none of those is a
/// reason to lose a history. What it costs them is stated plainly on the
/// consent surface — a second operator is a second copy, in a second
/// jurisdiction, extending this history's life for everyone in it a
/// second time (§14.11), and it is paid for twice.
///
/// Operators are independent all the way down. One failing, refusing
/// payment, publishing new terms, or never having been enrolled does not
/// stop the others: each returns its own outcome and the caller shows
/// them side by side.
public actor BackupFanOut {
    /// One operator, and the machinery pointed at it.
    public struct Vendor: Sendable {
        public let componentId: String
        /// What to call it on screen.
        public let displayName: String
        public let repository: BackupRepository
        /// This operator's local state, read for status without going
        /// through the actor.
        public let stateStore: any BackupStateStoring

        public init(
            componentId: String,
            displayName: String,
            repository: BackupRepository,
            stateStore: any BackupStateStoring
        ) {
            self.componentId = componentId
            self.displayName = displayName
            self.repository = repository
            self.stateStore = stateStore
        }
    }

    /// What happened at one operator.
    public enum VendorResult: Sendable, Equatable {
        case ran(BackupRepository.RunResult)
        /// The run threw. Kept as a message rather than an error so a
        /// result set stays `Sendable` and comparable — and so one
        /// operator's outage is a row on a screen rather than a thrown
        /// error that takes the other operators' results with it.
        case failed(message: String)
    }

    public struct Outcome: Sendable, Equatable, Identifiable {
        public let componentId: String
        public let displayName: String
        public let result: VendorResult
        /// True when this operator's row is the result of resuming a
        /// snapshot that had been refused for payment, rather than of
        /// this run's fresh one.
        ///
        /// The distinction is not pedantic. A resumed snapshot is as old
        /// as its contents, and the operator that took it is *not*
        /// holding what the others just received — so "backed up just
        /// now", which is what a local success time reads as, would be
        /// the summary rounding up again.
        public let resumedPayment: Bool
        public var id: String { componentId }
    }

    private let vendors: [Vendor]
    /// Operators whose row in the current run came from resuming a
    /// payment rather than from this run's snapshot.
    private var resumedPayments: Set<String> = []
    private let composer: BackupComposer
    /// The archive key ladder, which is derived from the recovery seed
    /// alone and is therefore identity-wide rather than per operator: a
    /// snapshot must be openable by whoever holds the phrase, not by
    /// whoever stored it. The *access* keys are per operator and live
    /// inside each repository.
    private let archiveRoot: SymmetricKey

    public init(vendors: [Vendor], composer: BackupComposer, archiveRoot: SymmetricKey) {
        self.vendors = vendors
        self.composer = composer
        self.archiveRoot = archiveRoot
    }

    public var componentIds: [String] { vendors.map(\.componentId) }

    /// Back up to every enrolled operator.
    ///
    /// The order is the whole design:
    ///
    /// 1. retry anything already sealed and refused for payment, byte for
    ///    byte, at the operator that refused it;
    /// 2. ask each operator whether a run may proceed at all;
    /// 3. if nobody can take one, stop — reading a whole history and
    ///    sealing it for an audience of nobody is expense for nothing;
    /// 4. read the history once;
    /// 5. seal it once *per* operator, each with its own fresh salt;
    /// 6. destroy the plaintext — before the first upload, not after the
    ///    last; and
    /// 7. upload, one operator at a time.
    ///
    /// Step 2 and step 7 both connect and reconcile, so a run costs two
    /// round trips per operator rather than one. That is deliberate: the
    /// second is a small request immediately before a multi-hundred-
    /// megabyte upload, it re-checks the terms pin against what the
    /// operator is publishing *now* rather than what it published before
    /// the seal, and the alternative — carrying a `BackupConnection`
    /// forward from step 2 — makes the upload's precondition a stale
    /// one.
    ///
    /// Uploads are sequential rather than concurrent. A snapshot is
    /// routinely hundreds of megabytes and this is a phone: two at once
    /// halves neither's time and doubles the chance both are interrupted.
    ///
    /// The cost of step 5 before step 7 is disk: every operator's sealed
    /// copy exists at once, so a run needs the snapshot's size times the
    /// number of operators. That is the deliberate side to pay on. The
    /// alternative — seal, upload, seal the next — keeps the plaintext
    /// archive on disk for the length of every transfer, and the
    /// plaintext is the one artefact here that anybody who reaches the
    /// container can read. An operator whose seal fails for want of
    /// space is reported as failed on its own row; the others still
    /// run.
    public func backUpAll(now: Date = Date()) async -> [Outcome] {
        var outcomes: [String: VendorResult] = [:]
        var candidates: [Vendor] = []
        resumedPayments = []

        // Before anything else: collect what earlier runs left. Sealed
        // bytes from a run that ended `unknown` are never re-read, and
        // without this they accumulate at full snapshot size, once per
        // operator, for the life of the install.
        await composer.sweepWorkingDirectory(claiming: claimedSealedBytes())

        for vendor in vendors {
            // An operator that has been consented to but never set up is
            // not part of this run and is not a failure of it. Its own
            // screen says "not set up", which is the honest word and the
            // one with something to do about it — a row here reading
            // "termsUnavailable" would be neither.
            //
            // An *unreadable* state file is a different thing entirely
            // and must not take the same exit: a locked device or a
            // corrupt file would silently drop the operator out of the
            // run, and a person would read the absence of a row as
            // nothing being wrong. The store already refuses to return
            // an empty state for that case; this refuses to invent one.
            let stored: BackupState
            do {
                stored = try vendor.stateStore.load()
            } catch {
                outcomes[vendor.componentId] = .failed(message: String(describing: error))
                continue
            }
            guard stored.acceptedTermsId != nil else { continue }

            if let settled = await retryPendingPayment(at: vendor, now: now) {
                outcomes[vendor.componentId] = settled
                // Resumed, so this operator is out of this run's fresh
                // compose: it has just been paid for and stored the
                // older snapshot, and sending the new one on top would
                // charge for storing the same history twice in one run.
                // The row says so rather than letting a fresh success
                // time imply otherwise.
                resumedPayments.insert(vendor.componentId)
                continue
            }
            do {
                switch try await vendor.repository.prepare(now: now) {
                case .ready:
                    candidates.append(vendor)
                case .blocked(let result):
                    outcomes[vendor.componentId] = .ran(result)
                }
            } catch {
                outcomes[vendor.componentId] = .failed(message: String(describing: error))
            }
        }

        guard !candidates.isEmpty else { return collate(outcomes) }

        let archive: BackupPlaintextArchive
        do {
            archive = try await composer.composeArchive(now: now)
        } catch {
            let message = String(describing: error)
            for vendor in candidates {
                outcomes[vendor.componentId] = .failed(message: message)
            }
            return collate(outcomes)
        }

        // Seal for everybody first, then destroy the plaintext. Sealing
        // is local and quick; uploading is neither. Destroying only
        // after the last upload would leave the one seed-readable
        // artefact on disk for the length of every transfer.
        var sealed: [(vendor: Vendor, snapshot: PreparedSnapshot)] = []
        for vendor in candidates {
            do {
                sealed.append((vendor, try await composer.seal(archive, archiveRoot: archiveRoot)))
            } catch {
                outcomes[vendor.componentId] = .failed(message: String(describing: error))
            }
        }
        archive.destroy()

        for (vendor, snapshot) in sealed {
            do {
                let result = try await vendor.repository.place(prepared: snapshot, now: now)
                outcomes[vendor.componentId] = .ran(result)
                switch result {
                case .paymentRequired:
                    // Owed a purchase, and `pendingPayment` resumes it
                    // from this exact file.
                    break
                case .unknown:
                    // Kept, but not because anything reads it back:
                    // reconciliation asks the operator and never
                    // re-opens the bytes. They are kept because the
                    // upload may have landed and deleting them mid-
                    // flight is worse than keeping them for a day. The
                    // sweep at the top of the next run collects them.
                    break
                case .retained, .alreadyRetained:
                    // The repository drops the bytes itself on the paths
                    // where it recorded a retention.
                    break
                case .termsChanged, .operatorChanged, .awaitingReconciliation, .alreadyRunning:
                    // Sealed for an operator that turned out not to be
                    // able to take it. Ciphertext nobody will claim.
                    snapshot.discard()
                }
            } catch {
                outcomes[vendor.componentId] = .failed(message: String(describing: error))
                // Deliberately kept. The upload may have landed and only
                // the answer been lost; the next run reconciles it, and
                // deleting the bytes now would leave nothing to retry
                // if it turns out it did not.
            }
        }
        return collate(outcomes)
    }

    /// Filenames the sweep must not touch: sealed bytes an operator is
    /// waiting on a purchase for, which are resumed byte for byte.
    private func claimedSealedBytes() -> Set<String> {
        Set(
            vendors.compactMap {
                (try? $0.stateStore.load())?.awaitingPayment?.sealedBytesFilename
            }
        )
    }

    /// Retry a snapshot one operator refused for payment.
    ///
    /// Per operator, byte for byte, and never across operators: those
    /// bytes are sealed for that operator, pinned to its terms, and owed
    /// a purchase made in its name. Returns `nil` when there was nothing
    /// to retry, or when the retry told us this operator needs something
    /// else first — in which case the ordinary run below decides what.
    private func retryPendingPayment(at vendor: Vendor, now: Date) async -> VendorResult? {
        let pending: SealedSnapshot?
        do {
            pending = try await vendor.repository.pendingPayment()
        } catch {
            return .failed(message: String(describing: error))
        }
        guard let pending else { return nil }
        do {
            let result = try await vendor.repository.retry(pending, now: now)
            switch result {
            case .retained, .alreadyRetained, .paymentRequired, .unknown, .alreadyRunning:
                return .ran(result)
            case .termsChanged, .operatorChanged, .awaitingReconciliation:
                // This snapshot is not sendable, and `pendingPayment`
                // has already cleared a record it cannot honour. What
                // this operator needs now is whatever the ordinary run
                // reports.
                return nil
            }
        } catch {
            return .failed(message: String(describing: error))
        }
    }

    /// One row per operator, in the order they were configured, so a
    /// screen does not reorder itself between runs.
    private func collate(_ outcomes: [String: VendorResult]) -> [Outcome] {
        vendors.compactMap { vendor in
            outcomes[vendor.componentId].map {
                Outcome(
                    componentId: vendor.componentId,
                    displayName: vendor.displayName,
                    result: $0,
                    resumedPayment: resumedPayments.contains(vendor.componentId)
                )
            }
        }
    }
}
