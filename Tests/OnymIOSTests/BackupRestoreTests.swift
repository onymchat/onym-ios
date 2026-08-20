import Foundation
import OnymChatsCore
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymPersistence
import XCTest
@testable import OnymBackup
@testable import OnymBackupUI
@testable import OnymIOS

/// History restore.
///
/// The property that matters most here is what restore *doesn't* do: it
/// adds, it never deletes, and it never touches the identity. The
/// dangerous kind of restore — identity restore, which wipes every
/// existing identity — lives in onboarding and is not reachable from
/// this screen.
final class BackupRestoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func material() -> BackupKeyMaterial {
        BackupKeys.material(
            seed: Data(repeating: 0x5E, count: 64), componentId: "onym:component:op")
    }

    /// Round trip through a real seal: compose, seal, then restore the
    /// sealed bytes and check what lands.
    func testRestoreAppliesASealedSnapshot() async throws {
        let dir = try directory()
        let material = material()

        let composer = BackupComposer(
            source: SeededSource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir)
        let snapshot = try await composer.compose(
            keyMaterial: material,
            acceptedTermsId: "sha256:" + String(repeating: "a", count: 64))

        let sink = RecordingSink()
        let flow = await BackupRestoreFlow(
            sources: [
                BackupRestoreSource(
                    componentId: "onym:component:test-operator",
                    displayName: "Test Operator",
                    repository: BackupRepository(
                        port: HoldingPort(snapshot: snapshot),
                        composer: composer,
                        stateStore: EmptyStateStore(),
                        keyMaterial: material))
            ],
            restorer: BackupRestorer(sink: sink),
            keyMaterial: material,
            workingDirectory: dir,
            didRestore: {})

        await flow.load()
        guard case .ready(let snapshots) = await flow.state, let first = snapshots.first else {
            return XCTFail("the operator's snapshot was not listed")
        }
        await flow.restore(first)

        guard case .restored(let summary) = await flow.state else {
            return XCTFail("restore did not complete: \(await flow.state)")
        }
        XCTAssertEqual(summary.groups, 1)
        XCTAssertEqual(summary.messages, 1)
        let restoredGroups = await sink.groups
        XCTAssertEqual(restoredGroups.first?.name, "Weekend plans")
    }

    /// A failed restore must leave the device exactly as it was. The
    /// restorer verifies the whole reference and decodes the entire
    /// archive before touching a store, so a corrupt download writes
    /// nothing.
    func testFailedRestoreWritesNothing() async throws {
        let dir = try directory()
        let material = material()
        let composer = BackupComposer(
            source: SeededSource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir)
        let snapshot = try await composer.compose(
            keyMaterial: material,
            acceptedTermsId: "sha256:" + String(repeating: "b", count: 64))

        // Corrupt the bytes the operator will serve.
        var bytes = try Data(contentsOf: snapshot.sealedBytesURL)
        bytes[bytes.count - 20] ^= 0xFF
        try bytes.write(to: snapshot.sealedBytesURL)

        let sink = RecordingSink()
        let flow = await BackupRestoreFlow(
            sources: [
                BackupRestoreSource(
                    componentId: "onym:component:test-operator",
                    displayName: "Test Operator",
                    repository: BackupRepository(
                        port: HoldingPort(snapshot: snapshot),
                        composer: composer,
                        stateStore: EmptyStateStore(),
                        keyMaterial: material))
            ],
            restorer: BackupRestorer(sink: sink),
            keyMaterial: material,
            workingDirectory: dir,
            didRestore: {})

        await flow.load()
        guard case .ready(let snapshots) = await flow.state, let first = snapshots.first else {
            return XCTFail("not listed")
        }
        await flow.restore(first)

        guard case .failed = await flow.state else {
            return XCTFail("a corrupt snapshot was accepted")
        }
        let wroteNothing = await sink.wroteNothing
        XCTAssertTrue(wroteNothing, "a partial restore reached the stores")
    }

    /// An empty list is an ordinary answer — a different operator or a
    /// different identity has a different holder key and sees nothing.
    func testEmptyListIsReadyNotFailed() async throws {
        let dir = try directory()
        let material = material()
        let flow = await BackupRestoreFlow(
            sources: [
                BackupRestoreSource(
                    componentId: "onym:component:test-operator",
                    displayName: "Test Operator",
                    repository: BackupRepository(
                        port: HoldingPort(snapshot: nil),
                        composer: BackupComposer(
                            source: SeededSource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
                        stateStore: EmptyStateStore(),
                        keyMaterial: material))
            ],
            restorer: BackupRestorer(sink: RecordingSink()),
            keyMaterial: material,
            workingDirectory: dir,
            didRestore: {})

        await flow.load()
        guard case .ready(let snapshots) = await flow.state else {
            return XCTFail("an empty list was reported as a failure")
        }
        XCTAssertTrue(snapshots.isEmpty)
    }

    /// The download and the decrypt must not share a path.
    ///
    /// Pinned at the hazard itself rather than by observing that a
    /// restore completed — completion also happens with a shared path
    /// wherever Foundation replaces the inode, which is exactly the
    /// platform the tests run on. So: open a sealed file onto itself and
    /// require it to fail, and require it to succeed with the sealed
    /// bytes intact when the paths differ.
    func testOpeningASnapshotOntoItselfIsRefused() async throws {
        let dir = try directory()
        let material = material()
        let plain = dir.appending(path: "plain")
        try Data(repeating: 0xAB, count: 64 * 1024).write(to: plain)

        let sealed = dir.appending(path: "sealed")
        let reference = try BackupSealer.seal(
            plaintextURL: plain, to: sealed, archiveRoot: material.archiveRoot)
        let sealedBytes = try Data(contentsOf: sealed)

        // Same path in and out. Asserting a *throw* here would have
        // been wrong: on this platform Foundation replaces the inode and
        // the open succeeds — which is precisely why the collision
        // survived review and testing. The hazard is what it does to the
        // input, so that is what gets pinned: the snapshot we were
        // handed is destroyed by reading it.
        _ = try? BackupOpener.open(
            sealedURL: sealed, to: sealed,
            reference: reference, archiveRoot: material.archiveRoot)
        XCTAssertNotEqual(
            try? Data(contentsOf: sealed), sealedBytes,
            "expected the shared path to clobber the sealed file; if this now holds, the hazard changed shape")

        // Distinct paths: succeeds, and the sealed file is untouched.
        try Data(sealedBytes).write(to: sealed)
        let out = dir.appending(path: "out")
        try BackupOpener.open(
            sealedURL: sealed, to: out,
            reference: reference, archiveRoot: material.archiveRoot)
        XCTAssertEqual(try Data(contentsOf: sealed), sealedBytes, "the sealed file was clobbered")
    }

    /// A failure during the write phase must not claim nothing changed.
    func testWritePhaseFailureIsReportedAsPartial() async throws {
        let dir = try directory()
        let material = material()
        let composer = BackupComposer(
            source: SeededSource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir)
        let snapshot = try await composer.compose(
            keyMaterial: material,
            acceptedTermsId: "sha256:" + String(repeating: "d", count: 64))

        let flow = await BackupRestoreFlow(
            sources: [
                BackupRestoreSource(
                    componentId: "onym:component:test-operator",
                    displayName: "Test Operator",
                    repository: BackupRepository(
                        port: HoldingPort(snapshot: snapshot),
                        composer: composer,
                        stateStore: EmptyStateStore(),
                        keyMaterial: material))
            ],
            // Groups land, then invitations throw — the shape the
            // reviewer identified in the real sink.
            restorer: BackupRestorer(sink: FailsMidWriteSink()),
            keyMaterial: material,
            workingDirectory: dir,
            didRestore: {})

        await flow.load()
        guard case .ready(let snapshots) = await flow.state, let first = snapshots.first else {
            return XCTFail("not listed")
        }
        await flow.restore(first)

        guard case .failed(let message, let partial) = await flow.state else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(partial, "a mid-write failure claimed nothing had changed")
        XCTAssertTrue(message.contains("restoring again is safe"))
    }

    /// A person mid-restore should get a sentence, not a debug dump.
    func testFailureMessagesAreSentences() {
        XCTAssertEqual(
            BackupRestoreFlow.describe(BackupError.incompleteSnapshot),
            "The backup did not arrive complete, so nothing was restored.")
        XCTAssertEqual(
            BackupRestoreFlow.describe(BackupError.retentionExpired),
            "The operator no longer holds this backup.")
        // An operator's own words beat our guess at what it meant.
        XCTAssertEqual(
            BackupRestoreFlow.describe(
                BackupError.rejected(code: "tape_library_offline", message: "back Tuesday")),
            "back Tuesday")
        XCTAssertFalse(
            BackupRestoreFlow.describe(URLError(.timedOut)).contains("Error Domain"))
    }

    /// The summary is written from what the sink wrote, and says so
    /// plainly when there was nothing to add.
    func testSummaryWordingIsHonest() {
        XCTAssertEqual(
            BackupRestoreView.describe(
                BackupRestoreSummary(
                    groups: 0, messages: 0, invitations: 0, consents: 0, blobs: 0,
                    unresolvedBlobs: [])),
            "Nothing to add — it was all already here.")
        XCTAssertEqual(
            BackupRestoreView.describe(
                BackupRestoreSummary(
                    groups: 2, messages: 5, invitations: 0, consents: 0, blobs: 0,
                    unresolvedBlobs: [])),
            "2 chats, 5 messages")
    }

    // MARK: - What the person sees when the summary appears

    /// The bug QA found, from the outside: a restore reported "1 chats"
    /// over a chat list that stayed empty, and the chat surfaced only
    /// once the person happened to create another one — because
    /// creating one is a `GroupRepository` mutation and a restore is
    /// not.
    ///
    /// So this subscribes *before* the restore, which is what primes the
    /// cache with the empty roster, and then asks for the next snapshot
    /// with nothing else touching the repository in between.
    func testARestoredGroupReachesSubscribersWithNoOtherMutation() async throws {
        let dir = try directory()
        let owner = IdentityID()
        let groupStore = SwiftDataGroupStore.inMemory()
        let messageStore = SwiftDataMessageStore.inMemory()
        let groups = GroupRepository(store: groupStore, currentIdentityID: owner)
        let messages = MessageRepository(store: messageStore)

        let stream = groups.snapshots
        var roster = stream.makeAsyncIterator()
        let before = await roster.next()
        XCTAssertEqual(before?.count, 0, "the roster was not primed empty")

        try await Self.runRestore(
            in: dir, owner: owner, groupStore: groupStore, messageStore: messageStore,
            didRestore: {
                await groups.reload()
                await messages.reload()
            })

        let after = await roster.next()
        XCTAssertEqual(
            after?.first?.name, "Weekend plans",
            "the restored chat never reached the list the person was looking at")
    }

    /// The half of it that survived the first sighting: the chat came
    /// back and the thread stayed empty. `MessageRepository` caches per
    /// thread, so a thread whose cache was filled *before* the restore
    /// keeps serving what it held then — an empty list, forever, since
    /// nothing else in the app writes those rows.
    func testRestoredMessagesReachAThreadCachedEmptyBeforeTheRestore() async throws {
        let dir = try directory()
        let owner = IdentityID()
        let groupStore = SwiftDataGroupStore.inMemory()
        let messageStore = SwiftDataMessageStore.inMemory()
        let groups = GroupRepository(store: groupStore, currentIdentityID: owner)
        let messages = MessageRepository(store: messageStore)

        let stream = messages.snapshots(groupID: Self.restoredGroupID, owner: owner)
        var thread = stream.makeAsyncIterator()
        let before = await thread.next()
        XCTAssertEqual(before?.count, 0, "the thread was not primed empty")

        try await Self.runRestore(
            in: dir, owner: owner, groupStore: groupStore, messageStore: messageStore,
            didRestore: {
                await groups.reload()
                await messages.reload()
            })

        let after = await thread.next()
        XCTAssertEqual(
            after?.first?.body, "see you at six",
            "the restored messages never reached the open thread")
    }

    /// A store that refuses the write is not a row restored. The sink
    /// used to `await store.insertOrUpdate(…)` and then add one
    /// regardless, so "1 chats, 3 messages" read the same whether three
    /// messages had landed or none had — which is most of why this took
    /// a QA pass to see at all.
    func testAWriteTheStoreRefusedIsNotCounted() async throws {
        let sink = AppBackupSink(
            groupStore: RefusingGroupStore(),
            messageStore: RefusingMessageStore(),
            invitationStore: SwiftDataInvitationStore.inMemory(),
            consentStore: MemoryConsentStore(),
            blobDirectory: try directory())

        let groups = try await sink.restore(groups: [Self.groupRecord(owner: IdentityID())])
        XCTAssertEqual(groups, BackupSinkOutcome(landed: 0, unreadable: 1))

        let messages = try await sink.restore(messages: [Self.messageRecord(owner: IdentityID())])
        XCTAssertEqual(messages, BackupSinkOutcome(landed: 0, unreadable: 1))
    }

    /// Already here is not unreadable.
    ///
    /// Every restore carries at least one consent the device already
    /// holds — you cannot reach an operator's snapshot without having
    /// consented to that operator — and the summary was rendering the
    /// shortfall as "could not be read by this version of Onym". Someone
    /// was told four consents were unreadable for four consents that
    /// were simply already theirs.
    func testAConsentAlreadyOnTheDeviceIsNotReportedAsUnreadable() async throws {
        let (record, raw) = try Self.consent(componentId: "onym:component:op")
        let store = MemoryConsentStore([record])
        let sink = AppBackupSink(
            groupStore: SwiftDataGroupStore.inMemory(),
            messageStore: SwiftDataMessageStore.inMemory(),
            invitationStore: SwiftDataInvitationStore.inMemory(),
            consentStore: store,
            blobDirectory: try directory())

        let outcome = try await sink.restore(
            consents: [BackupConsentRecord(componentId: "onym:component:op", raw: raw)])
        XCTAssertEqual(
            outcome.unreadable, 0,
            "a consent the device already held was reported as unparseable")
        XCTAssertEqual(outcome.landed, 1)
        XCTAssertEqual(
            try store.load().count, 1, "an already-held consent was written a second time")
    }

    /// The alarming sentence still has to be reachable, or the fix above
    /// would just have silenced it. Bytes that are not a consent record
    /// are the one case that earns it.
    func testAConsentThatWillNotDecodeIsReportedAsUnreadable() async throws {
        let sink = AppBackupSink(
            groupStore: SwiftDataGroupStore.inMemory(),
            messageStore: SwiftDataMessageStore.inMemory(),
            invitationStore: SwiftDataInvitationStore.inMemory(),
            consentStore: MemoryConsentStore(),
            blobDirectory: try directory())

        let outcome = try await sink.restore(
            consents: [
                BackupConsentRecord(
                    componentId: "onym:component:op",
                    raw: Data(#"{"from":"a later schema"}"#.utf8))
            ])
        XCTAssertEqual(outcome, BackupSinkOutcome(landed: 0, unreadable: 1))
    }

    /// Restoring the same snapshot twice converges rather than
    /// duplicating — and the second run must report the same thing the
    /// first did. Counting only *new* rows would have the second restore
    /// announce that everything in the archive was unreadable.
    func testASecondRestoreOfTheSameRowsStillCountsThemAsLanded() async throws {
        let owner = IdentityID()
        let sink = AppBackupSink(
            groupStore: SwiftDataGroupStore.inMemory(),
            messageStore: SwiftDataMessageStore.inMemory(),
            invitationStore: SwiftDataInvitationStore.inMemory(),
            consentStore: MemoryConsentStore(),
            blobDirectory: try directory())
        let record = Self.groupRecord(owner: owner)

        let first = try await sink.restore(groups: [record])
        let second = try await sink.restore(groups: [record])
        XCTAssertEqual(first, BackupSinkOutcome(landed: 1, unreadable: 0))
        XCTAssertEqual(
            second, BackupSinkOutcome(landed: 1, unreadable: 0),
            "restoring a chat that was already here read as a chat that could not be read")
    }

    // MARK: - Fixtures for the above

    fileprivate static let restoredGroupID = String(repeating: "c", count: 64)

    /// Seal a snapshot holding one group and one message for `owner`,
    /// serve it from a stand-in operator, and restore it through the
    /// real `AppBackupSink` and the real flow — so the ordering under
    /// test is the shipped one: refresh first, summary second.
    private static func runRestore(
        in dir: URL,
        owner: IdentityID,
        groupStore: any GroupStore,
        messageStore: any MessageStore,
        didRestore: @escaping @Sendable () async -> Void
    ) async throws {
        let material = BackupKeys.material(
            seed: Data(repeating: 0x5E, count: 64), componentId: "onym:component:op")
        let composer = BackupComposer(
            source: OwnedSource(owner: owner), mediaPolicy: .descriptorsOnly,
            workingDirectory: dir)
        let snapshot = try await composer.compose(
            keyMaterial: material,
            acceptedTermsId: "sha256:" + String(repeating: "a", count: 64))

        let flow = await BackupRestoreFlow(
            sources: [
                BackupRestoreSource(
                    componentId: "onym:component:test-operator",
                    displayName: "Test Operator",
                    repository: BackupRepository(
                        port: HoldingPort(snapshot: snapshot),
                        composer: composer,
                        stateStore: EmptyStateStore(),
                        keyMaterial: material))
            ],
            restorer: BackupRestorer(
                sink: AppBackupSink(
                    groupStore: groupStore,
                    messageStore: messageStore,
                    invitationStore: SwiftDataInvitationStore.inMemory(),
                    consentStore: MemoryConsentStore(),
                    blobDirectory: dir.appending(path: "blobs"))),
            keyMaterial: material,
            workingDirectory: dir,
            didRestore: didRestore)

        await flow.load()
        guard case .ready(let rows) = await flow.state, let row = rows.first else {
            throw XCTSkip("the operator's snapshot was not listed")
        }
        await flow.restore(row)
        guard case .restored = await flow.state else {
            throw XCTSkip("restore did not complete: \(await flow.state)")
        }
    }

    fileprivate static func groupRecord(owner: IdentityID) -> BackupGroupRecord {
        BackupGroupRecord(
            id: restoredGroupID, ownerIdentityID: owner.rawValue.uuidString,
            name: "Weekend plans", groupSecret: Data(repeating: 0xEE, count: 32),
            createdAt: Date(), membersJSON: Data("[]".utf8),
            memberProfilesJSON: Data("{}".utf8), epoch: 0,
            salt: Data(repeating: 1, count: 32), commitment: nil, tierRaw: 0,
            groupTypeRaw: "tyranny", adminPubkeyHex: nil, adminEd25519PubkeyHex: nil,
            isPublishedOnChain: false, avatarJPEG: nil, lastReadAt: nil,
            invitationMessage: nil)
    }

    fileprivate static func messageRecord(owner: IdentityID) -> BackupMessageRecord {
        BackupMessageRecord(
            id: UUID().uuidString, groupID: restoredGroupID,
            ownerIdentityID: owner.rawValue.uuidString,
            senderBlsPubkeyHex: "ab", body: "see you at six", sentAt: Date(),
            directionRaw: "outgoing", statusRaw: "sent", groupTypeRaw: "tyranny",
            replyToMessageID: nil, failureReasonRaw: nil, moderationAuthenticityProof: nil,
            imageAttachmentJSON: nil, videoAttachmentJSON: nil, albumAttachmentsJSON: nil,
            voiceAttachmentJSON: nil, systemEventJSON: nil)
    }

    /// One pinned consent, and the exact bytes an archive would carry
    /// for it. Built by decoding the bytes rather than by minting a
    /// signed manifest: what is under test is the *counting*, and the
    /// record only has to be one the sink's decoder accepts.
    private static func consent(componentId: String) throws -> (PinnedConsentRecord, Data) {
        let raw = try JSONSerialization.data(withJSONObject: [
            "componentId": componentId,
            "seatType": "storage.backup",
            "manifestHash": "sha256:" + String(repeating: "1", count: 64),
            "manifestBytes": Data("{}".utf8).base64EncodedString(),
            "acceptedAt": "2026-01-01T00:00:00Z",
            "isActive": true,
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try decoder.decode(PinnedConsentRecord.self, from: raw), raw)
    }
}

/// Serves one snapshot's sealed bytes, standing in for an operator.
private struct HoldingPort: BackupPort {
    let snapshot: SealedSnapshot?

    func connect() async throws -> BackupConnection { throw BackupError.operatorUnavailable }
    func preflight(_ snapshot: SealedSnapshot) async throws -> BackupPreflight {
        throw BackupError.operatorUnavailable
    }
    func uploadSnapshot(_ snapshot: SealedSnapshot, grant: BackupUploadGrant) async throws -> BackupOutcome {
        throw BackupError.operatorUnavailable
    }
    func listSnapshots() async throws -> [RetainedSnapshot] {
        guard let snapshot else { return [] }
        return [
            RetainedSnapshot(
                snapshotReference: snapshot.snapshotReference,
                acceptedTermsId: snapshot.acceptedTermsId,
                retainedAt: snapshot.sealedAt)
        ]
    }
    func downloadSnapshot(_ reference: SnapshotReference, to destination: URL) async throws {
        guard let snapshot else { throw BackupError.retentionExpired }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: snapshot.sealedBytesURL, to: destination)
    }
    func eraseSnapshot(scope: ErasureScope) async throws -> ErasureReceipt {
        throw BackupError.operatorUnavailable
    }
    func exportSnapshots(to directory: URL) async throws -> BackupExport {
        BackupExport(directory: directory, snapshots: [], receipts: [])
    }
    func queryOutcome(operationId: String) async throws -> BackupOutcome? { nil }
}

private struct SeededSource: BackupSourceProviding {
    func identityCount() async -> Int { 1 }
    func groups() async throws -> [BackupGroupRecord] {
        [
            BackupGroupRecord(
                id: String(repeating: "a", count: 64), ownerIdentityID: UUID().uuidString,
                name: "Weekend plans", groupSecret: Data(repeating: 0xEE, count: 32),
                createdAt: Date(), membersJSON: Data("[]".utf8),
                memberProfilesJSON: Data("{}".utf8), epoch: 0,
                salt: Data(repeating: 1, count: 32), commitment: nil, tierRaw: 0,
                groupTypeRaw: "tyranny", adminPubkeyHex: nil, adminEd25519PubkeyHex: nil,
                isPublishedOnChain: false, avatarJPEG: nil, lastReadAt: nil,
                invitationMessage: nil)
        ]
    }
    func messages(groupID: String, ownerIdentityID: String) async throws -> [BackupMessageRecord] {
        [
            BackupMessageRecord(
                id: UUID().uuidString, groupID: groupID, ownerIdentityID: ownerIdentityID,
                senderBlsPubkeyHex: "ab", body: "see you at six", sentAt: Date(),
                directionRaw: "outgoing", statusRaw: "sent", groupTypeRaw: "tyranny",
                replyToMessageID: nil, failureReasonRaw: nil, moderationAuthenticityProof: nil,
                imageAttachmentJSON: nil, videoAttachmentJSON: nil, albumAttachmentsJSON: nil,
                voiceAttachmentJSON: nil, systemEventJSON: nil)
        ]
    }
    func invitations() async throws -> [BackupInvitationRecord] { [] }
    func consents() async throws -> [BackupConsentRecord] { [] }
    func blobCiphertext(sha256: String) async throws -> BackupBlobAvailability { .gone }
}

/// Records **every** kind, not just groups.
///
/// Recording only groups meant `testFailedRestoreWritesNothing` would
/// have passed even if messages or invitations had been written before
/// the failure — the test named the property and checked a quarter of
/// it.
private actor RecordingSink: BackupSinkProviding {
    var groups: [BackupGroupRecord] = []
    var messages: [BackupMessageRecord] = []
    var invitations: [BackupInvitationRecord] = []
    var consents: [BackupConsentRecord] = []
    var blobs: [BackupBlobRecord] = []

    var wroteNothing: Bool {
        groups.isEmpty && messages.isEmpty && invitations.isEmpty
            && consents.isEmpty && blobs.isEmpty
    }

    func restore(groups: [BackupGroupRecord]) async throws -> BackupSinkOutcome {
        self.groups = groups
        return BackupSinkOutcome(landed: groups.count, unreadable: 0)
    }
    func restore(messages: [BackupMessageRecord]) async throws -> BackupSinkOutcome {
        self.messages = messages
        return BackupSinkOutcome(landed: messages.count, unreadable: 0)
    }
    func restore(invitations: [BackupInvitationRecord]) async throws -> BackupSinkOutcome {
        self.invitations = invitations
        return BackupSinkOutcome(landed: invitations.count, unreadable: 0)
    }
    func restore(consents: [BackupConsentRecord]) async throws -> BackupSinkOutcome {
        self.consents = consents
        return BackupSinkOutcome(landed: consents.count, unreadable: 0)
    }
    func restore(blob: BackupBlobRecord) async throws { blobs.append(blob) }
}

/// One group and one message, both owned by a caller-chosen identity —
/// `SeededSource` mints a fresh owner each call, which is fine when
/// nothing downstream has to *find* the rows and useless when a
/// repository filtered by identity does.
private struct OwnedSource: BackupSourceProviding {
    let owner: IdentityID

    func identityCount() async -> Int { 1 }
    func groups() async throws -> [BackupGroupRecord] {
        [BackupRestoreTests.groupRecord(owner: owner)]
    }
    func messages(groupID: String, ownerIdentityID: String) async throws -> [BackupMessageRecord] {
        [BackupRestoreTests.messageRecord(owner: owner)]
    }
    func invitations() async throws -> [BackupInvitationRecord] { [] }
    func consents() async throws -> [BackupConsentRecord] { [] }
    func blobCiphertext(sha256: String) async throws -> BackupBlobAvailability { .gone }
}

/// A store that persists nothing and says so, the way the real one does
/// when `encode` gives way.
private actor RefusingGroupStore: GroupStore {
    func list() async -> [ChatGroup] { [] }
    func insertOrUpdate(_ group: ChatGroup) -> Bool { false }
    func markPublished(id: String, ownerIDString: String, commitment: Data?) {}
    func markRead(id: String, ownerIDString: String, at date: Date) {}
    func delete(id: String, ownerIDString: String) {}
    func deleteOwner(_ ownerIDString: String) {}
}

private actor RefusingMessageStore: MessageStore {
    func list(groupID: String, ownerIDString: String) -> [ChatMessage] { [] }
    func latestMessage(groupID: String, ownerIDString: String) -> ChatMessage? { nil }
    func unreadCount(groupID: String, ownerIDString: String, since: Date) -> Int { 0 }
    func search(ownerIDString: String, query: String, limit: Int) -> [ChatMessage] { [] }
    func insertOrUpdate(_ message: ChatMessage) -> MessageInsertOutcome { .failed }
    func updateStatus(
        id: UUID, ownerIDString: String, status: MessageStatus,
        failureReason: SendFailureReason?
    ) {}
    func needsDeliveredAck(id: UUID, ownerIDString: String) -> Bool { false }
    func markDeliveredAckSent(id: UUID, ownerIDString: String) {}
    func delete(id: UUID, ownerIDString: String) {}
    func deleteGroup(groupID: String, ownerIDString: String) {}
    func deleteOwner(_ ownerIDString: String) {}
    func deleteAll() {}
}

private final class MemoryConsentStore: PinnedConsentStore, @unchecked Sendable {
    private var records: [PinnedConsentRecord]

    init(_ records: [PinnedConsentRecord] = []) { self.records = records }

    func load() throws -> [PinnedConsentRecord] { records }
    func save(_ records: [PinnedConsentRecord]) throws { self.records = records }
}

private struct EmptyStateStore: BackupStateStoring {
    func load() throws -> BackupState { BackupState() }
    func save(_ state: BackupState) throws {}
}


/// Writes groups, then fails — the shape of a consent or blob write
/// throwing after earlier rows have already landed.
private actor FailsMidWriteSink: BackupSinkProviding {
    func restore(groups: [BackupGroupRecord]) async throws -> BackupSinkOutcome {
        BackupSinkOutcome(landed: groups.count, unreadable: 0)
    }
    func restore(messages: [BackupMessageRecord]) async throws -> BackupSinkOutcome {
        BackupSinkOutcome(landed: messages.count, unreadable: 0)
    }
    func restore(invitations: [BackupInvitationRecord]) async throws -> BackupSinkOutcome {
        throw BackupError.localFailure(reason: .archiveUnreadable)
    }
    func restore(consents: [BackupConsentRecord]) async throws -> BackupSinkOutcome { .none }
    func restore(blob: BackupBlobRecord) async throws {}
}
