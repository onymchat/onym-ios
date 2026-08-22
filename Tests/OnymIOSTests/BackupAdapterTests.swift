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
        let visited = HostRecorder()
        StubURLProtocol.set { request in
            visited.record(request.url?.host())
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "https://elsewhere.example/v1/snapshots"])!
            return (Data(), response)
        }
        _ = try? await makeClient(session: session).listSnapshots()
        // The assertion that matters is *where the bytes went*, not that
        // an error came back — the previous version of this test passed
        // whether or not the redirect was followed, because the second
        // origin also hits the stub.
        XCTAssertEqual(visited.hosts, ["backup.example"])
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

    /// The erase request carries a client-chosen `operationId` — the
    /// operator refuses the body without one, which silently disabled
    /// the rolling window: every §11 erase came back 400, `makeRoom`
    /// swallowed it, and the sixth backup was refused `quota_exceeded`
    /// instead of evicting the oldest.
    func testEraseSendsAnOperationIdAndReadsTheReceiptArray() async throws {
        let seen = SendableBox()
        // The response shape the operator actually sends: an *array* of
        // receipts (one per pinned termsId in scope), stamped with
        // fractional seconds, which RFC 3339 allows and the operator's
        // clock produces.
        let termsId = "sha256:" + String(repeating: "a", count: 64)
        respond(
            200,
            #"""
            [{"receiptVersion":1,"receiptId":"r-1","operator":"onym:key:op",
              "scope":"sha256:\#(String(repeating: "b", count: 64))",
              "acknowledgedAt":"2026-08-22T13:42:25.779692Z",
              "completionCommittedBy":"2026-08-29T13:42:25.779692Z",
              "coveredScope":"primary and replicas",
              "excludedScope":"copies other participants hold",
              "termsId":"\#(termsId)"}]
            """#
        ) { seen.value = $0 }

        let reference = try SnapshotReference(
            digest: "sha256:" + String(repeating: "b", count: 64), sealedByteSize: 4)
        let receipts = try await makeClient().eraseSnapshot(scope: .snapshot(reference))

        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].receiptId, "r-1")
        XCTAssertEqual(receipts[0].termsId, termsId)

        let body = Self.body(of: seen.value)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let operationId = try XCTUnwrap(object["operationId"] as? String)
        XCTAssertFalse(operationId.isEmpty, "the operator refuses an erase without an id")
        XCTAssertEqual(object["scope"] as? String, reference.digest)
    }

    /// A `scope: "all"` spanning snapshots pinned to different terms is
    /// several receipts, and every one of them is evidence to keep.
    func testEraseAllKeepsEveryReceipt() async throws {
        let stamp = "2026-08-22T13:42:25.779692Z"
        let receipt: (String, String) -> String = { id, terms in
            #"""
            {"receiptVersion":1,"receiptId":"\#(id)","operator":"onym:key:op",
             "scope":"all","acknowledgedAt":"\#(stamp)",
             "completionCommittedBy":"\#(stamp)",
             "coveredScope":"primary and replicas",
             "excludedScope":"copies other participants hold",
             "termsId":"\#(terms)"}
            """#
        }
        let termsA = "sha256:" + String(repeating: "a", count: 64)
        let termsB = "sha256:" + String(repeating: "c", count: 64)
        respond(200, "[\(receipt("r-1", termsA)),\(receipt("r-2", termsB))]")

        let receipts = try await makeClient().eraseSnapshot(scope: .all)
        XCTAssertEqual(receipts.map(\.receiptId), ["r-1", "r-2"])
        XCTAssertEqual(receipts.map(\.termsId), [termsA, termsB])
    }

    /// An empty receipt array is an operator acknowledging nothing —
    /// this profile answers "nothing in scope" with an error, never an
    /// empty acknowledgement — and it must be *this* refusal, not an
    /// unrelated transport failure passing the test by accident.
    func testAnEmptyReceiptArrayIsRefused() async throws {
        respond(200, "[]")
        do {
            _ = try await makeClient().eraseSnapshot(scope: .all)
            XCTFail("an erasure with no receipt was accepted")
        } catch BackupError.rejected(let code, _) {
            XCTAssertEqual(code, "malformed_receipt")
        }
    }

    /// `rawBytes` is the durable record and the bytes a signature would
    /// be checked against, so each stored receipt must be the
    /// operator's exact bytes — key order, spacing, escapes and all —
    /// not a client re-serialization.
    func testStoredReceiptBytesAreTheOperatorsOwn() async throws {
        let termsId = "sha256:" + String(repeating: "a", count: 64)
        // Deliberately hostile to reconstruction: unsorted keys, odd
        // spacing, an escaped solidus, and a fractional stamp.
        let first = #"{"receiptId":"r-1", "operator":"onym:key:op","scope":"all",  "acknowledgedAt":"2026-08-22T13:42:25.779692123Z","completionCommittedBy":"2026-08-29T13:42:25+00:00","excludedScope":"copies\/exports","coveredScope":"primary","termsId":"\#(termsId)","receiptVersion":1}"#
        let second = #"{"receiptVersion":1,"receiptId":"r-2","operator":"onym:key:op","scope":"all","acknowledgedAt":"2026-08-22T13:42:25Z","completionCommittedBy":"2026-08-29T13:42:25Z","coveredScope":"primary","excludedScope":"copies other participants hold","termsId":"\#(termsId)"}"#
        respond(200, "[ \(first) ,\n\(second) ]")

        let receipts = try await makeClient().eraseSnapshot(scope: .all)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts[0].rawBytes, Data(first.utf8))
        XCTAssertEqual(receipts[1].rawBytes, Data(second.utf8))
    }

    /// A receipt whose `scope` is not the one requested is an operator
    /// answering a different question, and recording it would drop the
    /// local row for the requested digest on the strength of a receipt
    /// covering something else.
    func testAReceiptForADifferentScopeIsRefused() async throws {
        let termsId = "sha256:" + String(repeating: "a", count: 64)
        respond(
            200,
            #"""
            [{"receiptVersion":1,"receiptId":"r-1","operator":"onym:key:op",
              "scope":"sha256:\#(String(repeating: "e", count: 64))",
              "acknowledgedAt":"2026-08-22T13:42:25Z",
              "completionCommittedBy":"2026-08-29T13:42:25Z",
              "coveredScope":"primary and replicas",
              "excludedScope":"copies other participants hold",
              "termsId":"\#(termsId)"}]
            """#
        )
        let reference = try SnapshotReference(
            digest: "sha256:" + String(repeating: "b", count: 64), sealedByteSize: 4)
        do {
            _ = try await makeClient().eraseSnapshot(scope: .snapshot(reference))
            XCTFail("a receipt for a different scope was accepted")
        } catch BackupError.rejected(let code, _) {
            XCTAssertEqual(code, "scope_mismatch")
        }
    }

    /// The listing feeds the rolling window, and the operator's clock
    /// stamps fractional seconds — a listing refused for its timestamps
    /// is `makeRoom` silently never pruning again.
    func testListedTimestampsWithFractionalSecondsAreAccepted() async throws {
        let digest = "sha256:" + String(repeating: "d", count: 64)
        respond(
            200,
            #"""
            [{"snapshotReference":{"referenceVersion":1,
              "algorithm":"\#(BackupProfile.digestSuite)",
              "digest":"\#(digest)","sealedByteSize":4},
              "acceptedTermsId":"sha256:\#(String(repeating: "a", count: 64))",
              "retainedAt":"2026-08-22T13:42:25.779692123Z",
              "retainedUntil":null,"supersedes":null,"status":"retained"}]
            """#
        )
        let listed = try await makeClient().listSnapshots()
        XCTAssertEqual(listed.map(\.snapshotReference.digest), [digest])
    }

    /// Every stamp shape the operator's clock can emit: bare seconds,
    /// micro- and nanosecond fractions, and a numeric UTC offset.
    func testTheTimestampReaderAcceptsTheOperatorsClock() {
        for stamp in [
            "2026-08-22T13:42:25Z",
            "2026-08-22T13:42:25.779Z",
            "2026-08-22T13:42:25.779692Z",
            "2026-08-22T13:42:25.779692123Z",
            "2026-08-22T13:42:25+00:00",
            "2026-08-22T13:42:25.779692+00:00",
        ] {
            XCTAssertNotNil(BackupFormat.date(fromRFC3339: stamp), stamp)
        }
        XCTAssertNil(BackupFormat.date(fromRFC3339: "2026-08-22 13:42:25"))
    }

    /// Drain an intercepted request's body. `URLProtocol` hands the
    /// body back as a stream, not `httpBody`.
    private static func body(of request: URLRequest?) -> Data {
        guard let request else { return Data() }
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
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
        state.componentId = "onym:component:op"
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
        state.componentId = "onym:component:op"
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
        state.componentId = "onym:component:op"
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
        state.componentId = "onym:component:op"
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
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        state.pendingOperations = [
            BackupState.PendingOperation(operationId: "lost", digest: digest, sealedByteSize: 2048, startedAt: Date())
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
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        state.pendingOperations = [
            BackupState.PendingOperation(
                operationId: "lost",
                digest: "sha256:" + String(repeating: "8", count: 64),
                sealedByteSize: 2048, startedAt: Date())
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

    /// An operation the operator says is still `submitted` is in
    /// flight, not resolved. Dropping it would compose a second snapshot
    /// on top of one the operator is still working on — and charge for
    /// both.
    func testInFlightOperationStaysPending() async throws {
        let dir = try Self.directory()
        let digest = "sha256:" + String(repeating: "3", count: 64)
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        state.pendingOperations = [
            BackupState.PendingOperation(
                operationId: "inflight", digest: digest, sealedByteSize: 2048,
                startedAt: Date(), acceptedTermsId: ScriptedPort.termsId)
        ]
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true)
        await port.setQueryOutcome(
            BackupOutcome(operationId: "inflight", componentId: "onym:component:op",
                          status: .submitted))

        _ = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        XCTAssertEqual(try stateStore.load().pendingOperations.count, 1)
    }

    /// A query we could not make resolves nothing — the same rule as a
    /// list we could not fetch.
    func testFailedQueryLeavesPendingIntact() async throws {
        let dir = try Self.directory()
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        state.pendingOperations = [
            BackupState.PendingOperation(
                operationId: "lost", digest: "sha256:" + String(repeating: "4", count: 64),
                sealedByteSize: 2048, startedAt: Date(), acceptedTermsId: ScriptedPort.termsId)
        ]
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true)
        await port.setQueryFails(true)

        _ = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        XCTAssertEqual(try stateStore.load().pendingOperations.count, 1)
    }

    /// The operator does not get to say which snapshot we asked about.
    func testMismatchedEchoedReferenceIsRefused() async throws {
        let dir = try Self.directory()
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true)
        await port.setAlreadyRetainedEcho(
            try SnapshotReference(
                digest: "sha256:" + String(repeating: "5", count: 64), sealedByteSize: 99))

        do {
            _ = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
            XCTFail("accepted an answer about a different snapshot")
        } catch BackupError.rejected(let code, _) {
            XCTAssertEqual(code, "reference_mismatch")
        }
        XCTAssertTrue(try stateStore.load().snapshots.isEmpty, "the local chain was poisoned")
    }

    /// A purchase can outlive the process. The refused snapshot has to
    /// still be there afterwards, or the retry re-composes and the
    /// person pays twice.
    func testPendingPaymentSurvivesRelaunch() async throws {
        let dir = try Self.directory()
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId)

        guard case .paymentRequired(_, _, let pending) =
            try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        else {
            return XCTFail("expected a payment refusal")
        }

        // A fresh repository over the same state and directory — the
        // relaunch.
        let resumed = try await Self.repository(port: port, store: stateStore, dir: dir)
            .pendingPayment(in: dir)
        XCTAssertEqual(resumed?.operationId, pending.operationId)
        XCTAssertEqual(resumed?.snapshotReference, pending.snapshotReference)
        XCTAssertEqual(resumed?.acceptedTermsId, pending.acceptedTermsId)
    }

    /// A declared limit large enough to overflow the cap arithmetic must
    /// clamp, not trap. Every other operator-controlled figure earns a
    /// refusal; this one was earning a crash.
    func testHostileRetainedLimitDoesNotTrap() async throws {
        respond(200, "[]")
        let client = try makeClient(maximumRetainedSnapshots: Int.max)
        XCTAssertLessThanOrEqual(client.listResponseCap, URLSessionBackupClient.maxListResponseBytes)
        _ = try await client.listSnapshots()
    }

    /// A `retained` answer carrying no reference must not be able to
    /// wedge every future run. Reconcile ran before composing, so one
    /// unbuildable reference aborted `backUp` before it could save,
    /// leaving the operation unresolved and the next run to hit the same
    /// line — a permanent brick delivered by a *success* answer.
    func testTerseRetainedAnswerDoesNotWedgeFutureRuns() async throws {
        let dir = try Self.directory()
        let digest = "sha256:" + String(repeating: "6", count: 64)
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        state.pendingOperations = [
            BackupState.PendingOperation(
                operationId: "terse", digest: digest, sealedByteSize: 4096,
                startedAt: Date(), acceptedTermsId: ScriptedPort.termsId)
        ]
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true)
        // Retained, with nothing else said.
        await port.setQueryOutcome(
            BackupOutcome(operationId: "terse", componentId: "onym:component:op", status: .retained))

        _ = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        let saved = try stateStore.load()
        XCTAssertTrue(saved.pendingOperations.isEmpty, "the operation never resolved")
        XCTAssertTrue(saved.snapshots.contains { $0.digest == digest })
        XCTAssertEqual(
            saved.snapshots.first { $0.digest == digest }?.sealedByteSize, 4096,
            "believed the operator over our own record")

        // And the next run still works, which is the actual claim.
        _ = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
    }

    /// The issuers are the reason this refusal exists — without them a
    /// caller cannot know where to get a fresh credential.
    func testInvalidEntitlementCarriesIssuers() async throws {
        respond(401, #"{"error":"invalid_entitlement","message":"expired","entitlementIssuers":["onym:key:bb"]}"#)
        do {
            _ = try await makeClient().preflight(Self.snapshot())
            XCTFail("expected a refusal")
        } catch BackupError.invalidEntitlement(let issuers) {
            XCTAssertEqual(issuers, ["onym:key:bb"])
        }
    }

    /// An unreadable ancestor must not silently become "supersedes
    /// nothing" — that mints a snapshot claiming to start a new chain.
    func testCorruptAncestorIsRefusedRatherThanBreakingTheChain() async throws {
        let dir = try Self.directory()
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        state.snapshots = [
            BackupState.RecordedSnapshot(
                digest: "not-a-digest", sealedByteSize: 0,
                acceptedTermsId: ScriptedPort.termsId, uploadedAt: Date(),
                statusRaw: BackupOutcomeStatus.retained.rawValue)
        ]
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true)

        do {
            _ = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
            XCTFail("composed a snapshot that silently supersedes nothing")
        } catch BackupError.localFailure(let reason) {
            XCTAssertEqual(reason, .stateUnreadable)
        }
    }

    /// A caller-owned destination must not keep a partial file when the
    /// transfer fails partway.
    func testFailedDownloadLeavesNoPartialFile() async throws {
        let dir = try Self.directory()
        let destination = dir.appending(path: "snapshot")
        StubURLProtocol.set { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(repeating: 1, count: 32), response)
        }
        let reference = try SnapshotReference(
            digest: "sha256:" + String(repeating: "a", count: 64), sealedByteSize: 1 << 20)
        _ = try? await makeClient().downloadSnapshot(reference, to: destination)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a partial file was left at a caller-owned path")
    }

    /// Reconciling first only prevents double storage if failing to
    /// reconcile also stops us. Otherwise a run that cannot reach the
    /// operator mints a fresh salt and digest every time, and the
    /// operator retains each one beside the copy we lost track of.
    func testUnreconciledWorkBlocksComposition() async throws {
        let dir = try Self.directory()
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        state.pendingOperations = [
            BackupState.PendingOperation(
                operationId: "lost", digest: "sha256:" + String(repeating: "9", count: 64),
                sealedByteSize: 2048, startedAt: Date(), acceptedTermsId: ScriptedPort.termsId)
        ]
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true)
        await port.setListFails(true)

        let result = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        guard case .awaitingReconciliation(let ids) = result else {
            return XCTFail("composed a new snapshot over unresolved work: \(result)")
        }
        XCTAssertEqual(ids, ["lost"])
        let seen = await port.seenOperationIds
        XCTAssertTrue(seen.isEmpty, "a snapshot was preflighted despite unresolved work")
    }

    /// A pending operation resolved later is still older. Appending it
    /// to the tail would make the next snapshot supersede a stale
    /// ancestor.
    func testReconciledRetentionDoesNotBecomeTheNewestAncestor() throws {
        var state = BackupState()
        let older = try SnapshotReference(
            digest: "sha256:" + String(repeating: "1", count: 64), sealedByteSize: 1024)
        let newer = try SnapshotReference(
            digest: "sha256:" + String(repeating: "2", count: 64), sealedByteSize: 2048)

        state.record(reference: newer, acceptedTermsId: "t", at: Date(), status: .retained)
        // Resolved afterwards, but uploaded before.
        state.record(
            reference: older, acceptedTermsId: "t",
            at: Date().addingTimeInterval(-3600), status: .retained)

        XCTAssertEqual(state.newestSnapshot?.digest, newer.digest)
        XCTAssertEqual(state.snapshots.map(\.digest), [older.digest, newer.digest])
    }

    /// Resolving an operation must also close out any purchase it was
    /// waiting on, or the caller is stranded buying storage for a
    /// snapshot the operator already holds.
    func testResolvedOperationClearsThePendingPurchase() async throws {
        let dir = try Self.directory()
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId)

        guard case .paymentRequired(_, _, let pending) =
            try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        else {
            return XCTFail("expected a payment refusal")
        }

        // The operator turns out to hold it after all.
        var withPending = try stateStore.load()
        withPending.pendingOperations = [
            BackupState.PendingOperation(
                operationId: pending.operationId,
                digest: pending.snapshotReference.digest,
                sealedByteSize: pending.snapshotReference.sealedByteSize,
                startedAt: Date(), acceptedTermsId: ScriptedPort.termsId)
        ]
        try stateStore.save(withPending)
        await port.setRetained([
            RetainedSnapshot(
                snapshotReference: pending.snapshotReference,
                acceptedTermsId: ScriptedPort.termsId, retainedAt: Date())
        ])
        await port.setPaymentSatisfied(true)

        let repository = Self.repository(port: port, store: stateStore, dir: dir)
        _ = try await repository.backUp()
        XCTAssertNil(try stateStore.load().awaitingPayment, "still owes a purchase it does not need")
        let resumable = try await repository.pendingPayment(in: dir)
        XCTAssertNil(resumable)
    }

    /// Two interleaved runs must not each save a stale copy over the
    /// other — the loser would take the winner's pending record with it,
    /// and that record is the whole uncertainty design.
    func testConcurrentRunsAreSerialized() async throws {
        let dir = try Self.directory()
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        let stateStore = MemoryStateStore(state: state)
        let port = ScriptedPort(acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true)
        let repository = Self.repository(port: port, store: stateStore, dir: dir)

        async let first = repository.backUp()
        async let second = repository.backUp()
        let results = try await [first, second]
        XCTAssertEqual(results.filter { $0 == .alreadyRunning }.count, 1,
                       "both runs proceeded concurrently")
    }

    // MARK: - The rolling retention window

    /// A full operator refuses every later backup forever, because
    /// `supersedes` frees nothing. So the client makes room: one new
    /// snapshot, one erasure, and the upload goes through.
    func testAtTheLimitTheOldestIsErasedAndTheNewSnapshotLands() async throws {
        let dir = try Self.directory()
        let chain = try Self.agreedChain(count: 2)
        let stateStore = MemoryStateStore(state: Self.enrolled(holding: chain.recorded))
        let port = ScriptedPort(
            acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true, retainedLimit: 2)
        await port.setRetained(chain.rows)

        let result = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        guard case .retained = result else {
            return XCTFail("the backup was refused instead of making room: \(result)")
        }

        let erased = await port.erasedScopes
        let stillHeld = await port.retainedDigests
        XCTAssertEqual(
            erased, [chain.rows[0].snapshotReference.digest],
            "exactly the oldest retained snapshot should have gone, and only it")
        XCTAssertEqual(
            stillHeld, [chain.rows[1].snapshotReference.digest],
            "the most recent backup was erased to make room")

        let saved = try stateStore.load()
        XCTAssertEqual(saved.receipts.count, 1, "an erasure that left no receipt")
        XCTAssertFalse(
            saved.snapshots.contains { $0.digest == chain.rows[0].snapshotReference.digest },
            "the local chain still claims a snapshot this device erased")
    }

    /// Room to spare means nothing is touched. Pruning to a floor rather
    /// than to a fit would throw away backups the operator was happy to
    /// keep.
    func testBelowTheLimitNothingIsErased() async throws {
        let dir = try Self.directory()
        let chain = try Self.agreedChain(count: 2)
        let stateStore = MemoryStateStore(state: Self.enrolled(holding: chain.recorded))
        let port = ScriptedPort(
            acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true, retainedLimit: 5)
        await port.setRetained(chain.rows)

        _ = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        let erased = await port.erasedScopes
        XCTAssertEqual(erased, [], "erased with three slots still free")
        XCTAssertTrue(try stateStore.load().receipts.isEmpty)
    }

    /// An absent `maximumRetainedSnapshots` is absent, not a default.
    /// Erasing a person's backups to satisfy a limit nobody published
    /// would be the client inventing the rule it then enforces.
    func testAnOperatorDeclaringNoLimitIsNeverPruned() async throws {
        let dir = try Self.directory()
        let chain = try Self.agreedChain(count: 3)
        let stateStore = MemoryStateStore(state: Self.enrolled(holding: chain.recorded))
        let port = ScriptedPort(
            acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true, retainedLimit: nil)
        await port.setRetained(chain.rows)

        _ = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        let erased = await port.erasedScopes
        let stillHeld = await port.retainedDigests
        XCTAssertEqual(erased, [], "pruned against a limit the operator never declared")
        XCTAssertEqual(stillHeld.count, 3)
    }

    /// The window is opened before the upload, so an upload that then
    /// fails costs a slot. The claim being tested is the bound on that:
    /// what goes is always an *older* copy, and the person's most recent
    /// backup is still at the operator afterwards.
    func testAFailedUploadAfterPruningStillLeavesTheMostRecentBackup() async throws {
        let dir = try Self.directory()
        let chain = try Self.agreedChain(count: 2)
        let stateStore = MemoryStateStore(state: Self.enrolled(holding: chain.recorded))
        let port = ScriptedPort(
            acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true,
            uploadFails: true, retainedLimit: 2)
        await port.setRetained(chain.rows)

        guard case .unknown = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        else {
            return XCTFail("a lost upload must not resolve to success or failure")
        }
        let erased = await port.erasedScopes
        let stillHeld = await port.retainedDigests
        XCTAssertEqual(erased, [chain.rows[0].snapshotReference.digest])
        XCTAssertEqual(
            stillHeld, [chain.rows[1].snapshotReference.digest],
            "a failed upload left the holder with no backup at this operator")
    }

    /// An operator declaring a limit of one has nothing prunable: the
    /// only snapshot there is also the newest. Erasing it would leave
    /// the person with no backup at all for the length of an upload, so
    /// they get the operator's own refusal instead and can erase
    /// deliberately if that is what they want.
    func testTheOnlyBackupIsNeverErasedToMakeRoom() async throws {
        let dir = try Self.directory()
        let chain = try Self.agreedChain(count: 1)
        let stateStore = MemoryStateStore(state: Self.enrolled(holding: chain.recorded))
        let port = ScriptedPort(
            acceptedTermsId: ScriptedPort.termsId, paymentSatisfied: true, retainedLimit: 1)
        await port.setRetained(chain.rows)

        _ = try await Self.repository(port: port, store: stateStore, dir: dir).backUp()
        let erased = await port.erasedScopes
        XCTAssertEqual(
            erased, [],
            "erased the holder's only backup to make room for one still in flight")
    }

    // MARK: - Fixtures

    /// State for a device enrolled with the scripted operator, holding
    /// the given chain.
    static func enrolled(holding snapshots: [BackupState.RecordedSnapshot]) -> BackupState {
        var state = BackupState()
        state.componentId = "onym:component:op"
        state.acceptedTermsId = ScriptedPort.termsId
        state.snapshots = snapshots
        return state
    }

    /// `count` snapshots an hour apart, oldest first, that the operator
    /// is holding and this device remembers uploading.
    ///
    /// Both halves are needed and they are not interchangeable: the
    /// window is decided from the operator's list, while what the new
    /// snapshot supersedes comes from the local chain — and the ancestor
    /// a snapshot names is one of the two rows pruning must not touch.
    static func agreedChain(
        count: Int,
        now: Date = Date()
    ) throws -> (rows: [RetainedSnapshot], recorded: [BackupState.RecordedSnapshot]) {
        var rows: [RetainedSnapshot] = []
        var recorded: [BackupState.RecordedSnapshot] = []
        for index in 0..<count {
            let digest = "sha256:" + String(repeating: String(index + 1), count: 64)
            let at = now.addingTimeInterval(TimeInterval(-3600 * (count - index)))
            rows.append(
                RetainedSnapshot(
                    snapshotReference: try SnapshotReference(digest: digest, sealedByteSize: 2048),
                    acceptedTermsId: ScriptedPort.termsId,
                    retainedAt: at))
            recorded.append(
                BackupState.RecordedSnapshot(
                    digest: digest, sealedByteSize: 2048,
                    acceptedTermsId: ScriptedPort.termsId, uploadedAt: at,
                    statusRaw: BackupOutcomeStatus.retained.rawValue))
        }
        return (rows, recorded)
    }

    static func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func repository(
        port: any BackupPort,
        store: any BackupStateStoring,
        dir: URL
    ) -> BackupRepository {
        BackupRepository(
            port: port,
            composer: BackupComposer(
                source: EmptySource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
            stateStore: store,
            keyMaterial: BackupKeys.material(
                seed: Data(repeating: 0xEE, count: 64), componentId: "onym:component:op"))
    }

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
    private let retainedLimit: Int?
    private var retained: [RetainedSnapshot] = []
    private(set) var erasedScopes: [String] = []
    private var listFails = false
    private var queryOutcome: BackupOutcome?
    private var queryFails = false
    private var alreadyRetainedEcho: SnapshotReference?
    private(set) var seenOperationIds: [String] = []

    init(
        acceptedTermsId: String,
        paymentSatisfied: Bool = false,
        uploadFails: Bool = false,
        uploadStatus: BackupOutcomeStatus = .retained,
        retainedLimit: Int? = 8
    ) {
        self.acceptedTermsId = acceptedTermsId
        self.paymentSatisfied = paymentSatisfied
        self.uploadFails = uploadFails
        self.uploadStatus = uploadStatus
        self.retainedLimit = retainedLimit
    }

    var retainedDigests: [String] { retained.map(\.snapshotReference.digest) }

    func setRetained(_ rows: [RetainedSnapshot]) { retained = rows }
    func setListFails(_ value: Bool) { listFails = value }
    func setQueryOutcome(_ outcome: BackupOutcome?) { queryOutcome = outcome }
    func setQueryFails(_ value: Bool) { queryFails = value }
    func setPaymentSatisfied(_ value: Bool) { paymentSatisfied = value }
    func setAlreadyRetainedEcho(_ reference: SnapshotReference) { alreadyRetainedEcho = reference }

    func allowPayment() { paymentSatisfied = true }

    func connect() async throws -> BackupConnection {
        BackupConnection(
            manifest: try BackupAdapterTests.manifest(maximumRetainedSnapshots: retainedLimit),
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
        if let echo = alreadyRetainedEcho {
            return .alreadyRetained(
                BackupOutcome(
                    operationId: snapshot.operationId, componentId: "onym:component:op",
                    status: .alreadyRetained, snapshotReference: echo))
        }
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

    /// Erasure the way the operator performs it: the row stops being
    /// listed, and a receipt comes back. A stub that only recorded the
    /// call would let a test claim room was made without the list ever
    /// getting shorter.
    func eraseSnapshot(scope: ErasureScope) async throws -> [ErasureReceipt] {
        erasedScopes.append(scope.wireValue)
        if case .snapshot(let reference) = scope {
            retained.removeAll { $0.snapshotReference.digest == reference.digest }
        } else {
            retained.removeAll()
        }
        return [ErasureReceipt(
            receiptId: "receipt-\(erasedScopes.count)",
            operatorKey: "onym:key:" + String(repeating: "1", count: 64),
            scope: scope.wireValue,
            acknowledgedAt: Date(),
            completionCommittedBy: Date().addingTimeInterval(600),
            coveredScope: "primary and replicas",
            excludedScope: "copies other participants hold",
            termsId: Self.termsId,
            rawBytes: Data(#"{"receiptId":"\#(erasedScopes.count)"}"#.utf8),
            signature: nil)]
    }
    func exportSnapshots(to directory: URL) async throws -> BackupExport {
        BackupExport(directory: directory, snapshots: [], receipts: [])
    }
    func queryOutcome(operationId: String) async throws -> BackupOutcome? {
        if queryFails { throw BackupError.operatorUnavailable }
        return queryOutcome
    }

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


/// Records which hosts a stubbed session was actually asked to contact.
private final class HostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func record(_ host: String?) {
        guard let host else { return }
        lock.withLock { if !seen.contains(host) { seen.append(host) } }
    }

    var hosts: [String] { lock.withLock { seen } }
}
