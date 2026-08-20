import Foundation
import OnymFoundation
import XCTest
@testable import OnymBackup
@testable import OnymBackupUI
@testable import OnymBilling

/// The consent surface, checked by fixture rather than by review.
///
/// `UI-Backup.md` §18.10 asks for exactly this, and the reason is that a
/// disclosure is the one part of this seat that degrades silently: a
/// paragraph dropped in a refactor still compiles, still renders, and
/// still looks like a consent screen.
final class BackupDisclosureTests: XCTestCase {
    private func disclosure(
        mediaPolicy: BackupMediaPolicy = .descriptorsOnly,
        schedule: BackupSchedule = .default
    ) throws -> BackupDisclosure {
        let terms = try BackupTerms.decode(raw: Self.termsJSON)
        let manifest = try BackupOperatorManifest(
            manifest: SignedServiceManifest(raw: Self.manifestJSON(termsId: terms.termsId)))
        let profile = BackupImplementationProfile(
            implementationVersion: 1,
            implementationProfileId: BackupProfile.implementationProfileId,
            backupProfileId: BackupProfile.portableProfileId,
            digestSuite: BackupProfile.digestSuite,
            sealingSuite: BackupProfile.sealingSuite,
            incrementModel: BackupProfile.incrementModel,
            authentication: [BackupProfile.authentication],
            paymentRefusal: BackupProfile.paymentRefusal)
        return BackupDisclosure.from(
            connection: BackupConnection(manifest: manifest, profile: profile, terms: terms),
            schedule: schedule,
            mediaPolicy: mediaPolicy)
    }

    /// Every declared term reaches the surface. The list is spelled out
    /// rather than counted so that adding a field to `BackupTerms`
    /// without disclosing it fails here.
    func testEveryDeclaredTermIsDisclosed() throws {
        let ids = Set(try disclosure().items.map(\.id))
        let required: Set<String> = [
            "operator",
            "retention.class", "retention.period", "retention.count", "retention.expiry",
            "erasure.acknowledgement", "erasure.completion", "erasure.scope", "erasure.excluded",
            "jurisdictions", "subProcessors",
            "lawfulAccess.produces", "lawfulAccess.notify",
            "breach",
            "export.format", "export.unpaid", "shutdownNotice",
            "endOfPayment.notice", "endOfPayment.grace",
            "endOfPayment.duringGrace", "endOfPayment.afterGrace",
            "metadata.accessLogs", "metadata.sizeAndTiming",
            "media", "termsId",
        ]
        XCTAssertTrue(required.isSubset(of: ids), "missing: \(required.subtracting(ids).sorted())")
    }

    /// The sentence §7.4 requires. Asserted on substance, not wording,
    /// so a rewrite can improve the copy but not quietly drop the point.
    func testThirdPartyConsequenceIsStated() throws {
        let text = try disclosure().thirdPartyConsequence.lowercased()
        XCTAssertTrue(text.contains("both sides of every conversation"))
        XCTAssertTrue(text.contains("did not choose"))
    }

    /// §11: a person must learn there is no recovery here, not later.
    func testAbsentResetPathIsStated() throws {
        let text = try disclosure().noResetPath.lowercased()
        XCTAssertTrue(text.contains("recovery phrase"))
        XCTAssertTrue(text.contains("unreadable"))
        XCTAssertTrue(text.contains("no reset"))
    }

    /// The schedule copy must not promise more than the build does.
    /// Uploads happen on a tap and nowhere else — nothing calls
    /// `backUpIfDue` — so "automatic" would be a lie, and whole-snapshot
    /// means every run re-uploads everything.
    func testScheduleCopyDoesNotOverpromise() throws {
        let text = try disclosure().whenBackupsHappen.lowercased()
        XCTAssertTrue(text.contains("not in the background"))
        XCTAssertTrue(text.contains("does not back up on its own"))
        XCTAssertTrue(text.contains("whole history"))
        XCTAssertFalse(text.contains("automatically"))
    }

    /// What erasure does *not* reach is the part a person is likeliest
    /// to assume away, so it travels verbatim rather than summarised.
    func testExcludedErasureScopeIsVerbatim() throws {
        let item = try XCTUnwrap(try disclosure().items.first { $0.id == "erasure.excluded" })
        XCTAssertEqual(item.value, "copies other participants hold, and copies you exported")
    }

    /// Descriptors-only must say what it costs, rather than letting
    /// someone discover it when their media is gone.
    func testDescriptorsOnlyDisclosesItsMediaCost() throws {
        let item = try XCTUnwrap(try disclosure().items.first { $0.id == "media" })
        XCTAssertTrue(item.value.contains("gone if it no longer has them"))

        let included = try XCTUnwrap(
            try disclosure(mediaPolicy: .includeCiphertext).items.first { $0.id == "media" })
        XCTAssertEqual(included.value, "Included in the backup")
    }

    /// The schedule sentence describes what this build does, not what
    /// `BackupSchedule` could do.
    ///
    /// It used to assert the sentence tracked the policy — Wi-Fi in,
    /// charging out — which was a fine rule for copy about a behaviour
    /// that existed. `backUpIfDue` has no caller, so the sentence was
    /// describing an opportunistic run that never happens, on the screen
    /// whose whole job is to say what will happen. This pins the honest
    /// claim instead, and will fail the day somebody wires the schedule
    /// without revisiting the copy.
    func testScheduleSentenceClaimsOnlyWhatThisBuildDoes() {
        let sentence = BackupDisclosure.scheduleSentence(.default).lowercased()
        XCTAssertTrue(sentence.contains("when you tap back up now"))
        XCTAssertTrue(sentence.contains("does not back up on its own"))
        XCTAssertFalse(sentence.contains("may also"))
    }

    func testOpportunisticRunRespectsConditions() {
        let schedule = BackupSchedule.default
        let ready = BackupSchedule.Conditions(
            onWiFi: true, charging: true, lastSuccessAt: nil, lastAttemptAt: nil)
        XCTAssertTrue(schedule.permitsOpportunisticRun(ready, jitter: 0))

        var cellular = ready
        cellular.onWiFi = false
        XCTAssertFalse(schedule.permitsOpportunisticRun(cellular, jitter: 0))

        var recent = ready
        recent.lastAttemptAt = Date()
        XCTAssertFalse(schedule.permitsOpportunisticRun(recent, jitter: 0))
    }

    /// A backup that quietly stopped working has to be a visible state
    /// (§7.15), which starts with the flow calling it stale.
    func testNeverBackedUpCountsAsStale() {
        XCTAssertTrue(BackupSchedule.default.isStale(lastSuccessAt: nil))
        XCTAssertFalse(BackupSchedule.default.isStale(lastSuccessAt: Date()))
    }

    /// The gate this screen's central claim rests on.
    ///
    /// The first version set the flag from an `onAppear` sentinel in a
    /// plain `VStack`, which fires at initial layout for offscreen
    /// children — so "Turn On Backup" was enabled before anyone read a
    /// word. Tested through the pure predicate now, because a claim
    /// about consent that only a human can check is the claim most
    /// likely to quietly stop being true.
    func testScrollGateOnlyOpensAtTheEnd() {
        // A long disclosure, sitting at the top: not read.
        XCTAssertFalse(
            BackupEnrolmentView.hasReachedEnd(
                contentOffsetY: 0, containerHeight: 800, contentHeight: 4000))

        // Halfway: still not read.
        XCTAssertFalse(
            BackupEnrolmentView.hasReachedEnd(
                contentOffsetY: 1600, containerHeight: 800, contentHeight: 4000))

        // At the bottom: read.
        XCTAssertTrue(
            BackupEnrolmentView.hasReachedEnd(
                contentOffsetY: 3200, containerHeight: 800, contentHeight: 4000))
    }

    /// Content shorter than the screen has already been read in full.
    /// Gating on a scroll that can never happen would lock the button
    /// forever — a failure that only shows up on a large display.
    func testShortDisclosureCountsAsRead() {
        XCTAssertTrue(
            BackupEnrolmentView.hasReachedEnd(
                contentOffsetY: 0, containerHeight: 1200, contentHeight: 900))
    }

    /// A declared-but-unapplied jitter is decoration on top of the
    /// activity signal it claims to suppress.
    func testJitterDelaysTheOpportunisticRun() {
        let schedule = BackupSchedule.default
        let lastAttempt = Date()
        let conditions = BackupSchedule.Conditions(
            onWiFi: true, charging: true, lastSuccessAt: lastAttempt, lastAttemptAt: lastAttempt)

        // Exactly one interval later, with two hours of jitter drawn:
        // not yet.
        let atInterval = lastAttempt.addingTimeInterval(schedule.minimumInterval)
        XCTAssertFalse(
            schedule.permitsOpportunisticRun(conditions, jitter: 7200, now: atInterval))

        // Past the interval plus the jitter: now.
        let afterJitter = lastAttempt.addingTimeInterval(schedule.minimumInterval + 7201)
        XCTAssertTrue(
            schedule.permitsOpportunisticRun(conditions, jitter: 7200, now: afterJitter))
    }

    /// Drawn jitter stays inside its declared bound, so the copy that
    /// describes the cadence cannot be wrong about it.
    func testDrawnJitterRespectsItsBound() {
        let schedule = BackupSchedule.default
        for _ in 0..<64 {
            let jitter = schedule.drawJitter()
            XCTAssertGreaterThanOrEqual(jitter, 0)
            XCTAssertLessThanOrEqual(jitter, schedule.maximumJitter)
        }
    }

    /// The cadence sentence follows the configured interval rather than
    /// asserting a day beside a value that can change.
    func testCadenceTracksTheInterval() {
        XCTAssertEqual(BackupDisclosure.cadence(24 * 3600), "once a day")
        XCTAssertEqual(BackupDisclosure.cadence(72 * 3600), "once every 3 days")
        XCTAssertEqual(BackupDisclosure.cadence(6 * 3600), "once every 6 hours")
    }

    /// Switching operators must not hand the new one the old one's
    /// operational state.
    ///
    /// The dangerous member is `awaitingPayment`: a snapshot sealed
    /// under operator A's terms and pinned to A's digest, retried
    /// against B, is a person paying B to store something that pins
    /// terms B never published.
    func testRebindDiscardsThePreviousOperatorsWork() throws {
        var state = BackupState()
        state.componentId = "onym:component:a"
        state.acceptedTermsId = "sha256:" + String(repeating: "a", count: 64)
        state.lastSuccessAt = Date()
        state.lastAttemptAt = Date()
        state.record(
            reference: try SnapshotReference(
                digest: "sha256:" + String(repeating: "1", count: 64), sealedByteSize: 1024),
            acceptedTermsId: state.acceptedTermsId!, at: Date(), status: .retained)
        state.pendingOperations = [
            BackupState.PendingOperation(
                operationId: "a-op", digest: "sha256:" + String(repeating: "2", count: 64),
                sealedByteSize: 2048, startedAt: Date(), acceptedTermsId: state.acceptedTermsId)
        ]
        state.awaitingPayment = BackupState.PendingPayment(
            operationId: "a-pay", digest: "sha256:" + String(repeating: "3", count: 64),
            sealedByteSize: 4096, sealedBytesFilename: "pending-a",
            acceptedTermsId: state.acceptedTermsId!, supersedesDigest: nil,
            supersedesByteSize: nil, sealedAt: Date(), refusedAt: Date())
        state.receipts = [Data("receipt from a".utf8)]

        let orphan = state.rebind(to: "onym:component:b")

        XCTAssertEqual(orphan, "pending-a", "the sealed bytes were left to rot in the directory")
        XCTAssertEqual(state.componentId, "onym:component:b")
        XCTAssertTrue(state.snapshots.isEmpty)
        XCTAssertTrue(state.pendingOperations.isEmpty)
        XCTAssertNil(state.awaitingPayment, "a snapshot sealed under A's terms could be sent to B")
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertNil(state.lastAttemptAt)

        // Receipts survive: evidence of something that happened, never
        // acted on, and the only durable record of what an erasure did
        // not reach.
        XCTAssertEqual(state.receipts.count, 1)
    }

    /// Re-enrolling with the *same* operator is not a switch and must
    /// not throw away a backup chain.
    func testRebindToTheSameOperatorKeepsEverything() throws {
        var state = BackupState()
        state.componentId = "onym:component:a"
        state.record(
            reference: try SnapshotReference(
                digest: "sha256:" + String(repeating: "1", count: 64), sealedByteSize: 1024),
            acceptedTermsId: "t", at: Date(), status: .retained)

        XCTAssertNil(state.rebind(to: "onym:component:a"))
        XCTAssertEqual(state.snapshots.count, 1)
    }

    /// A first enrolment has no previous operator to discard, but does
    /// have to record which one it is now.
    func testRebindFromNoOperatorRecordsIt() {
        var state = BackupState()
        XCTAssertNil(state.rebind(to: "onym:component:a"))
        XCTAssertEqual(state.componentId, "onym:component:a")
    }

    /// The reverse lookup a replay depends on has no way to choose
    /// between two components sharing a product, so it refuses — a
    /// replay we cannot attribute is retried, where crediting the wrong
    /// operator is not recoverable.
    func testAmbiguousProductIdIsRefused() {
        let shared = ChannelOffer(
            channelOfferId: "sha256:x", componentId: "onym:component:a",
            offerId: "o1", productId: "app.onym.backup.monthly",
            productType: "auto-renewable-subscription",
            operatorShareBps: 7000, frontendCommissionBps: 3000)
        let clash = ChannelOffer(
            channelOfferId: "sha256:y", componentId: "onym:component:b",
            offerId: "o2", productId: "app.onym.backup.monthly",
            productType: "auto-renewable-subscription",
            operatorShareBps: 7000, frontendCommissionBps: 3000)

        // Both sides of the clash are dropped at construction, so the
        // lookup cannot attribute a replay to a guess — and no assert
        // fires mid-replay to crash a debug build.
        let catalog = ChannelOfferCatalog(offers: [shared, clash])
        XCTAssertEqual(catalog.rejectedProductIds, ["app.onym.backup.monthly"])
        XCTAssertNil(catalog.offer(forProductId: "app.onym.backup.monthly"))

        let clean = ChannelOfferCatalog(offers: [shared])
        XCTAssertEqual(clean.offer(forProductId: "app.onym.backup.monthly")?.offerId, "o1")
        XCTAssertTrue(clean.rejectedProductIds.isEmpty)
    }

    /// The gap that made the previous fix unreachable.
    ///
    /// `rebind` only runs from enrolment, enrolment was only offered at
    /// `.off`, and `.off` required no stored terms — so after consenting
    /// to a new operator the old terms id was still there, the status
    /// read as enrolled, and every Back Up Now returned `termsChanged`
    /// with no route back to the consent screen. A protection that only
    /// runs on first enrolment is not a protection against switching.
    func testStatesThatNeedEnrolmentOfferIt() {
        let cases: [(DeviceBackupSettingsFlow.Status, Bool)] = [
            (.off, true),
            (.termsChanged, true),
            (.operatorChanged, true),
            (.idle(lastSuccessAt: nil), false),
            (.running, false),
            (.stale(lastSuccessAt: nil), false),
            (.checkingEarlierBackup, false),
            (.paymentRequired(offerIds: []), false),
        ]
        for (status, expected) in cases {
            XCTAssertEqual(
                DeviceBackupSettingsFlow.needsEnrolment(for: status), expected,
                "\(status) should\(expected ? "" : " not") offer enrolment")
        }
    }

    /// State written before the operator was recorded has
    /// `componentId == nil`, and nothing ever stamped it — so every
    /// guard added for operator switching silently passed. `nil` is not
    /// "matches"; it is "cannot tell", and the safe reading of that is
    /// a switch.
    func testUnrecordedOperatorIsTreatedAsASwitch() throws {
        var state = BackupState()
        state.acceptedTermsId = "sha256:" + String(repeating: "a", count: 64)
        XCTAssertNil(state.componentId)

        // The rebind that enrolment performs stamps it, and only then
        // does a matching operator read as unchanged.
        XCTAssertNil(state.rebind(to: "onym:component:a"))
        XCTAssertEqual(state.componentId, "onym:component:a")
        XCTAssertNil(state.rebind(to: "onym:component:a"))
    }

    /// A run that finishes after someone re-enrolled must not write its
    /// stale copy back — that would resurrect the previous operator's id
    /// and pending work, undoing the rebind silently.
    ///
    /// The previous version of this test built a repository, never
    /// called it, and asserted state it had saved itself. It passed
    /// vacuously and was exactly the test that should have caught
    /// `backUp` still using raw saves. This one drives `backUp` and has
    /// the *port* perform the re-enrolment mid-run, which is when it
    /// really happens: during one of the awaits.
    func testStaleWriteAfterRebindIsRefused() async throws {
        let dir = try Self.seamDirectory()
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = RebindingPort.termsId
        state.pendingOperations = [
            BackupState.PendingOperation(
                operationId: "a-op", digest: "sha256:" + String(repeating: "1", count: 64),
                sealedByteSize: 1024, startedAt: Date(),
                acceptedTermsId: RebindingPort.termsId)
        ]
        let store = MemorySeamStore(state: state)

        // `connect()` rebinds the store to a different operator, standing
        // in for the person completing enrolment while this run is in
        // flight.
        let port = RebindingPort(store: store)
        let repository = BackupRepository(
            port: port,
            composer: BackupComposer(
                source: EmptySeamSource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: store,
            keyMaterial: BackupKeys.material(
                seed: Data(repeating: 0x1A, count: 64), componentId: "onym:component:op"))

        _ = try? await repository.backUp()

        let after = try store.load()
        XCTAssertEqual(after.componentId, "onym:component:b", "the rebind was undone")
        XCTAssertTrue(after.pendingOperations.isEmpty, "operator A's work was resurrected")
        XCTAssertNil(after.acceptedTermsId, "the new operator's enrolment was overwritten")
    }

    /// A pending payment whose sealed bytes are gone buys nothing, and
    /// the record must go with them — otherwise Settings sits on
    /// "Payment needed" forever, including after later backups succeed.
    func testPendingPaymentWithMissingBytesIsCleared() async throws {
        let dir = try Self.seamDirectory()
        var state = BackupState()
        state.componentId = "onym:component:a"
        state.acceptedTermsId = RebindingPort.termsId
        state.awaitingPayment = BackupState.PendingPayment(
            operationId: "gone", digest: "sha256:" + String(repeating: "2", count: 64),
            sealedByteSize: 2048, sealedBytesFilename: "pending-gone",
            acceptedTermsId: RebindingPort.termsId, supersedesDigest: nil,
            supersedesByteSize: nil, sealedAt: Date(), refusedAt: Date())
        let store = MemorySeamStore(state: state)

        let repository = BackupRepository(
            port: RebindingPort(store: MemorySeamStore(state: BackupState())),
            composer: BackupComposer(
                source: EmptySeamSource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: store,
            keyMaterial: BackupKeys.material(
                seed: Data(repeating: 0x1B, count: 64), componentId: "onym:component:a"))

        let resumable = try await repository.pendingPayment(in: dir)
        XCTAssertNil(resumable)
        XCTAssertNil(try store.load().awaitingPayment, "a purchase that can buy nothing is still owed")
    }

    static func seamDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Fixtures

    static func manifestJSON(termsId: String) -> Data {
        Data("""
        {"version":1,"componentId":"onym:component:op","seat":"storage.backup",
         "operator":"onym:key:\(String(repeating: "1", count: 64))",
         "backupProfileId":"\(BackupProfile.portableProfileId)",
         "implementationProfileId":"\(BackupProfile.implementationProfileId)",
         "endpoints":[{"uri":"https://backup.example","role":"read-write"}],
         "capabilities":["upload","list","download","erase","export"],
         "declaredTerms":"\(termsId)"}
        """.utf8)
    }

    static let termsJSON = Data("""
    {"termsVersion":1,"operator":"onym:key:\(String(repeating: "1", count: 64))",
     "retention":{"class":"measurable","maximumRetentionPeriod":"P1Y",
       "snapshotsRetained":"3","expiryBehavior":"notify-then-erase"},
     "erasure":{"acknowledgementDeadline":"P1D","completionDeadline":"P7D",
       "scope":"primary and declared replicas",
       "excluded":"copies other participants hold, and copies you exported"},
     "jurisdictions":["EE"],"subProcessors":[],
     "lawfulAccess":{"disclosureWhatIsProduced":"sealed-bytes-and-declared-metadata-only",
       "notifyHolderWhenPermitted":true,"transparencyReporting":null},
     "breachDisclosure":{"holderNotice":"P3D"},
     "export":{"format":"tar","availableWhileUnpaid":true},
     "shutdownNotice":"P90D",
     "endOfPayment":{"notice":"P14D","grace":"P30D",
       "duringGrace":["download","export","erase"],"afterGrace":"erase"},
     "metadataRetention":{"accessLogs":"none","sizeAndTiming":"P1Y",
       "holderIdentifiers":"P1Y","operationOutcomes":"PT6H",
       "erasureReceipts":"P1Y","entitlementRecords":"P1Y"}}
    """.utf8)
}

private final class MemorySeamStore: BackupStateStoring, @unchecked Sendable {
    private var state: BackupState
    private let lock = NSLock()
    init(state: BackupState) { self.state = state }
    func load() throws -> BackupState { lock.withLock { state } }
    func save(_ state: BackupState) throws { lock.withLock { self.state = state } }
}

private struct EmptySeamSource: BackupSourceProviding {
    func identityCount() async -> Int { 0 }
    func groups() async throws -> [BackupGroupRecord] { [] }
    func messages(groupID: String, ownerIdentityID: String) async throws -> [BackupMessageRecord] { [] }
    func invitations() async throws -> [BackupInvitationRecord] { [] }
    func consents() async throws -> [BackupConsentRecord] { [] }
    func blobCiphertext(sha256: String) async throws -> BackupBlobAvailability { .gone }
}


/// Performs a re-enrolment during `connect()`, which is where one
/// really lands: inside one of `backUp`'s awaits.
private struct RebindingPort: BackupPort {
    /// The digest the fixture terms actually hash to, so the run's
    /// terms check passes and it proceeds to a write.
    static var termsId: String {
        (try? BackupTerms.decode(raw: BackupDisclosureTests.termsJSON).termsId) ?? ""
    }
    let store: any BackupStateStoring

    func connect() async throws -> BackupConnection {
        var rebound = try store.load()
        rebound.rebind(to: "onym:component:b")
        rebound.acceptedTermsId = nil
        try store.save(rebound)

        // And then *succeed*, reporting the operator the run still
        // believes it is talking to. This is the whole point: an earlier
        // version of this port threw here, so `backUp` unwound before it
        // ever reached a save and the test passed with the bug
        // reinstated. The run has to get as far as writing.
        let terms = try BackupTerms.decode(raw: BackupDisclosureTests.termsJSON)
        return BackupConnection(
            manifest: try BackupOperatorManifest(
                manifest: SignedServiceManifest(
                    raw: BackupDisclosureTests.manifestJSON(termsId: terms.termsId))),
            profile: BackupImplementationProfile(
                implementationVersion: 1,
                implementationProfileId: BackupProfile.implementationProfileId,
                backupProfileId: BackupProfile.portableProfileId,
                digestSuite: BackupProfile.digestSuite,
                sealingSuite: BackupProfile.sealingSuite,
                incrementModel: BackupProfile.incrementModel,
                authentication: [BackupProfile.authentication],
                paymentRefusal: BackupProfile.paymentRefusal),
            terms: terms)
    }

    func preflight(_ snapshot: SealedSnapshot) async throws -> BackupPreflight {
        throw BackupError.operatorUnavailable
    }
    func uploadSnapshot(_ snapshot: SealedSnapshot, grant: BackupUploadGrant) async throws -> BackupOutcome {
        throw BackupError.operatorUnavailable
    }
    func listSnapshots() async throws -> [RetainedSnapshot] { [] }
    func downloadSnapshot(_ reference: SnapshotReference, to destination: URL) async throws {}
    func eraseSnapshot(scope: ErasureScope) async throws -> ErasureReceipt {
        throw BackupError.operatorUnavailable
    }
    func exportSnapshots(to directory: URL) async throws -> BackupExport {
        BackupExport(directory: directory, snapshots: [], receipts: [])
    }
    func queryOutcome(operationId: String) async throws -> BackupOutcome? { nil }
}

/// A pending payment sealed under terms that have since been superseded
/// can never be sent, so the record must go with them.
extension BackupDisclosureTests {
    func testPendingPaymentUnderSupersededTermsIsCleared() async throws {
        let dir = try Self.seamDirectory()
        let sealed = dir.appending(path: "pending-old")
        try Data(repeating: 7, count: 32).write(to: sealed)

        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = "sha256:" + String(repeating: "n", count: 64)
        state.awaitingPayment = BackupState.PendingPayment(
            operationId: "old", digest: "sha256:" + String(repeating: "2", count: 64),
            sealedByteSize: 32, sealedBytesFilename: "pending-old",
            // Pinned to the *previous* terms.
            acceptedTermsId: "sha256:" + String(repeating: "o", count: 64),
            supersedesDigest: nil, supersedesByteSize: nil,
            sealedAt: Date(), refusedAt: Date())
        let store = MemorySeamStore(state: state)

        let repository = BackupRepository(
            port: RebindingPort(store: MemorySeamStore(state: BackupState())),
            composer: BackupComposer(
                source: EmptySeamSource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: store,
            keyMaterial: BackupKeys.material(
                seed: Data(repeating: 0x2B, count: 64), componentId: "onym:component:op"))

        let resumable = try await repository.pendingPayment(in: dir)
        XCTAssertNil(resumable)
        XCTAssertNil(try store.load().awaitingPayment, "Settings would sit on Payment needed forever")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sealed.path),
            "sealed bytes nobody will ever send were kept")
    }
}
