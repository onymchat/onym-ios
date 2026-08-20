import CryptoKit
import Foundation
import OnymFoundation
import XCTest
@testable import OnymBackup

/// The wire adapter and the repository state machine.
///
/// Most of these assert a *refusal*. That is the shape of this seat: the
/// operator is outside the trust boundary, so what the client declines
/// to believe is more load-bearing than what it accepts.
final class BackupAdapterTests: XCTestCase {
    private let endpoint = URL(string: "https://backup.example")!

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(
        maximumRetainedSnapshots: Int? = 8,
        session: URLSession? = nil
    ) throws -> URLSessionBackupClient {
        URLSessionBackupClient(
            manifest: try Self.manifest(maximumRetainedSnapshots: maximumRetainedSnapshots),
            material: BackupKeys.material(
                seed: Data(repeating: 0x77, count: 64), componentId: "onym:component:op"),
            session: session ?? StubURLProtocol.makeSession()
        )
    }

    private func respond(
        _ status: Int,
        _ json: String,
        capture: (@Sendable (URLRequest) -> Void)? = nil
    ) {
        StubURLProtocol.set { request in
            capture?(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (Data(json.utf8), response)
        }
    }

    // MARK: - Refusals

    /// A 402 must arrive as a payment refusal carrying the offer the
    /// person is being asked to buy — not as a generic failure the UI
    /// can only render as "something went wrong".
    func testPaymentRequiredCarriesTheOffer() async throws {
        respond(402, """
        {"error":"payment_required","message":"no entitlement",
         "paymentRequired":{"componentId":"onym:component:op",
         "offers":["backup-monthly-v1"],"entitlementIssuers":["onym:key:aa"]}}
        """)
        do {
            _ = try await makeClient().preflight(Self.snapshot())
            XCTFail("expected a payment refusal")
        } catch BackupError.paymentRequired(let componentId, let offers, let issuers) {
            XCTAssertEqual(componentId, "onym:component:op")
            XCTAssertEqual(offers, ["backup-monthly-v1"])
            XCTAssertEqual(issuers, ["onym:key:aa"])
        }
    }

    /// An operator inventing a status word must never be read as
    /// success by a client that has never heard of it.
    func testUnrecognisedStatusBecomesUnknownNotRetained() async throws {
        respond(200, #"{"outcome":{"status":"definitely_fine","componentId":"onym:component:op"}}"#)
        let outcome = try await makeClient().queryOutcome(operationId: "abc")
        XCTAssertEqual(outcome?.status, .unknown)
        XCTAssertFalse(outcome?.status.isRetention ?? true)
    }

    /// `submitted` means the bytes were handed to the network. It is not
    /// retention and must not be recorded as such.
    func testSubmittedIsNotRetention() {
        XCTAssertFalse(BackupOutcomeStatus.submitted.isRetention)
        XCTAssertFalse(BackupOutcomeStatus.accepted.isRetention)
        XCTAssertTrue(BackupOutcomeStatus.retained.isRetention)
        XCTAssertTrue(BackupOutcomeStatus.alreadyRetained.isRetention)
    }

    /// The response body's only soft bound is a figure the same operator
    /// published, so the cap has to be ours.
    func testOversizedListResponseIsRefused() async throws {
        let row = #"{"snapshotReference":{"referenceVersion":1,"algorithm":"sha-256/lowercase-hex","digest":"sha256:\#(String(repeating: "a", count: 64))","sealedByteSize":1},"acceptedTermsId":"sha256:\#(String(repeating: "b", count: 64))","retainedAt":"2026-01-01T00:00:00Z"}"#
        respond(200, "[" + Array(repeating: row, count: 4_000).joined(separator: ",") + "]")
        do {
            _ = try await makeClient(maximumRetainedSnapshots: 2).listSnapshots()
            XCTFail("expected the oversized body to be refused")
        } catch BackupError.operatorUnavailable {
            // Expected.
        }
    }

    /// A signature covers one path at one origin. An operator that could
    /// redirect would be choosing where our credentials go.
    func testRedirectsAreRefused() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(
            configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
        StubURLProtocol.set { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "https://elsewhere.example/v1/snapshots"])!
            return (Data(), response)
        }
        do {
            _ = try await makeClient(session: session).listSnapshots()
            XCTFail("expected the redirect not to be followed")
        } catch {
            // Either the 302 surfaces as a rejection or the body fails
            // to decode — both mean we did not go to the other origin.
        }
    }

    /// An unmodelled operator code is preserved rather than flattened
    /// into a local guess about what happened.
    func testUnknownOperatorCodeIsPreservedVerbatim() async throws {
        respond(409, #"{"error":"tape_library_offline","message":"back Tuesday"}"#)
        do {
            _ = try await makeClient().preflight(Self.snapshot())
            XCTFail("expected a rejection")
        } catch BackupError.rejected(let code, let message) {
            XCTAssertEqual(code, "tape_library_offline")
            XCTAssertEqual(message, "back Tuesday")
        }
    }

    /// Every `/v1/` request carries the four proof headers, and the
    /// holder is spelled as a seat key.
    func testRequestsAreSigned() async throws {
        let seen = SendableBox()
        respond(200, #"{"outcome":{"status":"unknown"}}"#) { seen.value = $0 }
        _ = try? await makeClient().queryOutcome(operationId: "abc")
        let headers = seen.value?.allHTTPHeaderFields ?? [:]
        XCTAssertTrue(headers["X-Onym-Holder"]?.hasPrefix("onym:seat-key:") ?? false)
        XCTAssertNotNil(headers["X-Onym-Timestamp"])
        XCTAssertNotNil(headers["X-Onym-Nonce"])
        XCTAssertNotNil(headers["X-Onym-Signature"])
    }

    // MARK: - Repository

    /// A payment refusal keeps the sealed bytes, and the retry sends the
    /// same operation id and the same digest. Re-composing would mint a
    /// new salt, defeat `already_retained`, and charge for a second copy
    /// of the same history.
    func testPaymentRetrySendsTheSameBytes() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let material = BackupKeys.material(
            seed: Data(repeating: 0x88, count: 64), componentId: "onym:component:op")
        let termsId = ScriptedPort.termsId
        XCTAssertFalse(termsId.isEmpty)

        var state = BackupState()
        state.acceptedTermsId = termsId
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: termsId)

        let repository = BackupRepository(
            port: port,
            composer: BackupComposer(
                source: EmptySource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: stateStore,
            keyMaterial: material)

        guard case .paymentRequired(_, _, let pending) = try await repository.backUp() else {
            return XCTFail("expected a payment refusal")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.sealedBytesURL.path),
                      "sealed bytes were discarded on a refusal a purchase would resolve")

        await port.allowPayment()
        let result = try await repository.retry(pending)
        XCTAssertEqual(result, .retained(pending.snapshotReference))
        let operationIds = await port.seenOperationIds
        XCTAssertEqual(operationIds.count, 2)
        XCTAssertEqual(operationIds[0], operationIds[1], "the retry composed a new snapshot")
    }

    /// A lost upload response is unresolved, not failed and not
    /// succeeded — and the record of it must survive, or the uncertainty
    /// is gone by the next launch.
    func testLostUploadResponseLeavesAPendingOperation() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let termsId = ScriptedPort.termsId
        var state = BackupState()
        state.acceptedTermsId = termsId
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: termsId, paymentSatisfied: true, uploadFails: true)

        let repository = BackupRepository(
            port: port,
            composer: BackupComposer(
                source: EmptySource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: stateStore,
            keyMaterial: BackupKeys.material(
                seed: Data(repeating: 0x99, count: 64), componentId: "onym:component:op"))

        guard case .unknown = try await repository.backUp() else {
            return XCTFail("a lost response must not resolve to success or failure")
        }
        let saved = try stateStore.load()
        XCTAssertEqual(saved.pendingOperations.count, 1)
        XCTAssertTrue(saved.snapshots.isEmpty, "an unresolved upload was recorded as retained")
    }

    /// Changed terms stop the upload. Re-pinning without a person having
    /// seen the new terms is the one thing this seat exists to prevent.
    func testChangedTermsStopTheUpload() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stalePin = "sha256:" + String(repeating: "e", count: 64)
        var state = BackupState()
        state.acceptedTermsId = stalePin
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId)

        let repository = BackupRepository(
            port: port,
            composer: BackupComposer(
                source: EmptySource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: stateStore,
            keyMaterial: BackupKeys.material(
                seed: Data(repeating: 0xAA, count: 64), componentId: "onym:component:op"))

        guard case .termsChanged(let current) = try await repository.backUp() else {
            return XCTFail("expected the upload to stop")
        }
        XCTAssertEqual(current, ScriptedPort.termsId)
        let saved = try stateStore.load()
        XCTAssertEqual(saved.acceptedTermsId, stalePin,
                       "the pinned terms were silently replaced")
    }

    /// `submitted` is not retention, and the pending record has to
    /// survive it. Clearing the record here would mean reconcile never
    /// re-queries and the uncertainty is gone — "silence is not success"
    /// holding only until the next line of code.
    func testNonRetentionOutcomeKeepsThePendingRecord() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var state = BackupState()
        state.acceptedTermsId = ScriptedPort.termsId
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(
            acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true, uploadStatus: .submitted)

        let repository = BackupRepository(
            port: port,
            composer: BackupComposer(
                source: EmptySource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: stateStore,
            keyMaterial: BackupKeys.material(
                seed: Data(repeating: 0xBB, count: 64), componentId: "onym:component:op"))

        guard case .unknown = try await repository.backUp() else {
            return XCTFail("`submitted` must not read as success")
        }
        let saved = try stateStore.load()
        XCTAssertEqual(saved.pendingOperations.count, 1, "the uncertainty was discarded")
        XCTAssertTrue(saved.snapshots.isEmpty)
    }

    /// A pending operation resolves against the retained list, which is
    /// the authority on what is held. Without this it would be re-queried
    /// forever once the operator's outcome record expires — the profile
    /// keeps those for hours.
    func testPendingResolvesAgainstTheRetainedList() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = "sha256:" + String(repeating: "7", count: 64)
        var state = BackupState()
        state.acceptedTermsId = ScriptedPort.termsId
        state.pendingOperations = [
            BackupState.PendingOperation(operationId: "lost", digest: digest, startedAt: Date())
        ]
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true)
        await port.setRetained([
            RetainedSnapshot(
                snapshotReference: try SnapshotReference(digest: digest, sealedByteSize: 2048),
                acceptedTermsId: ScriptedPort.termsId,
                retainedAt: Date())
        ])

        let repository = BackupRepository(
            port: port,
            composer: BackupComposer(
                source: EmptySource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: stateStore,
            keyMaterial: BackupKeys.material(
                seed: Data(repeating: 0xCC, count: 64), componentId: "onym:component:op"))
        _ = try await repository.backUp()

        let saved = try stateStore.load()
        XCTAssertTrue(
            saved.pendingOperations.allSatisfy { $0.operationId != "lost" },
            "a resolved operation stayed pending")
        XCTAssertTrue(saved.snapshots.contains { $0.digest == digest })
    }

    /// A list we could not fetch resolves nothing. Uncertainty must
    /// survive a failed reconciliation rather than be cleared by it.
    func testFailedListLeavesPendingIntact() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var state = BackupState()
        state.acceptedTermsId = ScriptedPort.termsId
        state.pendingOperations = [
            BackupState.PendingOperation(
                operationId: "lost",
                digest: "sha256:" + String(repeating: "8", count: 64),
                startedAt: Date())
        ]
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true)
        await port.setListFails(true)

        let repository = BackupRepository(
            port: port,
            composer: BackupComposer(
                source: EmptySource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: stateStore,
            keyMaterial: BackupKeys.material(
                seed: Data(repeating: 0xDD, count: 64), componentId: "onym:component:op"))
        _ = try await repository.backUp()

        XCTAssertEqual(try stateStore.load().pendingOperations.count, 1)
    }

    /// A grant whose arithmetic does not describe our file is refused
    /// before a byte is sent — an over-large chunk size would trap on
    /// the offset computation, and an under-count would upload a
    /// truncated snapshot that only fails at commit.
    func testHostileUploadGrantIsRefused() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sealed = dir.appending(path: "sealed")
        try Data(repeating: 5, count: 4096).write(to: sealed)
        let snapshot = SealedSnapshot(
            operationId: "op",
            snapshotReference: try SnapshotReference(
                digest: "sha256:" + String(repeating: "a", count: 64), sealedByteSize: 4096),
            sealedBytesURL: sealed, sealedAt: Date(),
            acceptedTermsId: ScriptedPort.termsId)

        for grant in [
            BackupUploadGrant(uploadId: "u", chunkBytes: Int.max, chunkCount: 1,
                              expiresAt: Date().addingTimeInterval(60)),
            BackupUploadGrant(uploadId: "u", chunkBytes: 1024, chunkCount: 1,
                              expiresAt: Date().addingTimeInterval(60)),
        ] {
            do {
                _ = try await makeClient().uploadSnapshot(snapshot, grant: grant)
                XCTFail("accepted a grant that does not describe the file")
            } catch BackupError.localFailure(let reason) {
                XCTAssertEqual(reason, .invalidUploadGrant)
            }
        }
    }

    /// A body shorter than the reference is a truncated file, not a
    /// successful download.
    func testShortDownloadIsRefused() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appending(path: "snapshot")
        StubURLProtocol.set { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(repeating: 1, count: 10), response)
        }
        let reference = try SnapshotReference(
            digest: "sha256:" + String(repeating: "a", count: 64), sealedByteSize: 4096)
        do {
            try await makeClient().downloadSnapshot(reference, to: destination)
            XCTFail("a short body was accepted")
        } catch BackupError.incompleteSnapshot {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// An unreadable-but-present state file must not read as a first
    /// run: the next save would overwrite the pinned terms and every
    /// pending operation with an empty file.
    func testUnreadableStateFileThrowsRatherThanReadingAsEmpty() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "state.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try FileBackupStateStore(url: url).load())

        // Absent is still a first run.
        let fresh = dir.appending(path: "absent.json")
        XCTAssertEqual(try FileBackupStateStore(url: fresh).load(), BackupState())
    }

    // MARK: - Fixtures

    static func manifest(maximumRetainedSnapshots: Int?) throws -> BackupOperatorManifest {
        var limits = ""
        if let maximumRetainedSnapshots {
            limits = #","limits":{"maximumRetainedSnapshots":\#(maximumRetainedSnapshots)}"#
        }
        let json = """
        {"version":1,"componentId":"onym:component:op","seat":"storage.backup",
         "operator":"onym:key:\(String(repeating: "1", count: 64))",
         "backupProfileId":"\(BackupProfile.portableProfileId)",
         "implementationProfileId":"\(BackupProfile.implementationProfileId)",
         "endpoints":[{"uri":"https://backup.example","role":"read-write"}],
         "capabilities":["upload","list","download","erase","export"],
         "declaredTerms":"sha256:\(String(repeating: "9", count: 64))"\(limits)}
        """
        return try BackupOperatorManifest(manifest: SignedServiceManifest(raw: Data(json.utf8)))
    }

    static func snapshot() -> SealedSnapshot {
        SealedSnapshot(
            operationId: "op",
            snapshotReference: try! SnapshotReference(
                digest: "sha256:" + String(repeating: "a", count: 64), sealedByteSize: 1024),
            sealedBytesURL: URL(fileURLWithPath: "/dev/null"),
            sealedAt: Date(),
            acceptedTermsId: "sha256:" + String(repeating: "b", count: 64))
    }
}

private final class SendableBox: @unchecked Sendable {
    var value: URLRequest?
}

private struct EmptySource: BackupSourceProviding {
    func identityCount() async -> Int { 0 }
    func groups() async throws -> [BackupGroupRecord] { [] }
    func messages(groupID: String, ownerIdentityID: String) async throws -> [BackupMessageRecord] { [] }
    func invitations() async throws -> [BackupInvitationRecord] { [] }
    func consents() async throws -> [BackupConsentRecord] { [] }
    func blobCiphertext(sha256: String) async throws -> BackupBlobAvailability { .gone }
}

private final class MemoryStateStore: BackupStateStoring, @unchecked Sendable {
    private var state: BackupState
    private let lock = NSLock()

    init(state: BackupState) { self.state = state }
    func load() throws -> BackupState { lock.withLock { state } }
    func save(_ state: BackupState) throws { lock.withLock { self.state = state } }
}

private actor ScriptedPort: BackupPort {
    private let acceptedTermsId: String
    private var paymentSatisfied: Bool
    private let uploadFails: Bool
    private let uploadStatus: BackupOutcomeStatus
    private var retained: [RetainedSnapshot] = []
    private var listFails = false
    private(set) var seenOperationIds: [String] = []

    init(
        acceptedTermsId: String,
        paymentSatisfied: Bool = false,
        uploadFails: Bool = false,
        uploadStatus: BackupOutcomeStatus = .retained
    ) {
        self.acceptedTermsId = acceptedTermsId
        self.paymentSatisfied = paymentSatisfied
        self.uploadFails = uploadFails
        self.uploadStatus = uploadStatus
    }

    func setRetained(_ rows: [RetainedSnapshot]) { retained = rows }
    func setListFails(_ value: Bool) { listFails = value }

    func allowPayment() { paymentSatisfied = true }

    func connect() async throws -> BackupConnection {
        BackupConnection(
            manifest: try BackupAdapterTests.manifest(maximumRetainedSnapshots: 8),
            profile: BackupImplementationProfile(
                implementationVersion: 1,
                implementationProfileId: BackupProfile.implementationProfileId,
                backupProfileId: BackupProfile.portableProfileId,
                digestSuite: BackupProfile.digestSuite,
                sealingSuite: BackupProfile.sealingSuite,
                incrementModel: BackupProfile.incrementModel,
                authentication: [BackupProfile.authentication],
                paymentRefusal: BackupProfile.paymentRefusal),
            terms: try BackupTerms.decode(raw: Self.termsJSON()))
    }

    func preflight(_ snapshot: SealedSnapshot) async throws -> BackupPreflight {
        seenOperationIds.append(snapshot.operationId)
        guard paymentSatisfied else {
            throw BackupError.paymentRequired(
                componentId: "onym:component:op",
                offerIds: ["backup-monthly-v1"],
                entitlementIssuers: [])
        }
        return .granted(
            BackupUploadGrant(
                uploadId: "u", chunkBytes: 8 << 20,
                chunkCount: 1, expiresAt: Date().addingTimeInterval(600)))
    }

    func uploadSnapshot(_ snapshot: SealedSnapshot, grant: BackupUploadGrant) async throws -> BackupOutcome {
        if uploadFails { throw BackupError.operatorUnavailable }
        return BackupOutcome(
            operationId: snapshot.operationId,
            componentId: "onym:component:op",
            status: uploadStatus,
            snapshotReference: snapshot.snapshotReference)
    }

    func listSnapshots() async throws -> [RetainedSnapshot] {
        if listFails { throw BackupError.operatorUnavailable }
        return retained
    }
    func downloadSnapshot(_ reference: SnapshotReference, to destination: URL) async throws {}
    func eraseSnapshot(scope: ErasureScope) async throws -> ErasureReceipt {
        throw BackupError.operatorUnavailable
    }
    func exportSnapshots(to directory: URL) async throws -> BackupExport {
        BackupExport(directory: directory, snapshots: [], receipts: [])
    }
    func queryOutcome(operationId: String) async throws -> BackupOutcome? { nil }

    /// The digest of the terms fixture below, computed the same way the
    /// client computes it. Fabricating one here would have made every
    /// terms comparison in these tests pass or fail for the wrong
    /// reason.
    static var termsId: String {
        (try? BackupTerms.decode(raw: termsJSON()).termsId) ?? ""
    }

    /// The terms document `connect()` hands back.
    static func termsJSON() -> Data {
        Data("""
        {"termsVersion":1,"operator":"onym:key:\(String(repeating: "1", count: 64))",
         "retention":{"class":"measurable","maximumRetentionPeriod":"P1Y",
           "snapshotsRetained":"3","expiryBehavior":"notify-then-erase"},
         "erasure":{"acknowledgementDeadline":"P1D","completionDeadline":"P7D",
           "scope":"primary and replicas","excluded":"copies other participants hold"},
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
}
