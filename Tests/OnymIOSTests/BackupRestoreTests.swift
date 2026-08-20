import Foundation
import XCTest
@testable import OnymBackup
@testable import OnymBackupUI

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
            repository: BackupRepository(
                port: HoldingPort(snapshot: snapshot),
                composer: composer,
                stateStore: EmptyStateStore(),
                keyMaterial: material),
            restorer: BackupRestorer(sink: sink),
            keyMaterial: material,
            workingDirectory: dir)

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
            repository: BackupRepository(
                port: HoldingPort(snapshot: snapshot),
                composer: composer,
                stateStore: EmptyStateStore(),
                keyMaterial: material),
            restorer: BackupRestorer(sink: sink),
            keyMaterial: material,
            workingDirectory: dir)

        await flow.load()
        guard case .ready(let snapshots) = await flow.state, let first = snapshots.first else {
            return XCTFail("not listed")
        }
        await flow.restore(first)

        guard case .failed = await flow.state else {
            return XCTFail("a corrupt snapshot was accepted")
        }
        let wrote = await sink.groups
        XCTAssertTrue(wrote.isEmpty, "a partial restore reached the stores")
    }

    /// An empty list is an ordinary answer — a different operator or a
    /// different identity has a different holder key and sees nothing.
    func testEmptyListIsReadyNotFailed() async throws {
        let dir = try directory()
        let material = material()
        let flow = await BackupRestoreFlow(
            repository: BackupRepository(
                port: HoldingPort(snapshot: nil),
                composer: BackupComposer(
                    source: SeededSource(), mediaPolicy: .descriptorsOnly, workingDirectory: dir),
                stateStore: EmptyStateStore(),
                keyMaterial: material),
            restorer: BackupRestorer(sink: RecordingSink()),
            keyMaterial: material,
            workingDirectory: dir)

        await flow.load()
        guard case .ready(let snapshots) = await flow.state else {
            return XCTFail("an empty list was reported as a failure")
        }
        XCTAssertTrue(snapshots.isEmpty)
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

private actor RecordingSink: BackupSinkProviding {
    var groups: [BackupGroupRecord] = []

    func restore(groups: [BackupGroupRecord]) async throws -> Int {
        self.groups = groups
        return groups.count
    }
    func restore(messages: [BackupMessageRecord]) async throws -> Int { messages.count }
    func restore(invitations: [BackupInvitationRecord]) async throws -> Int { 0 }
    func restore(consents: [BackupConsentRecord]) async throws -> Int { 0 }
    func restore(blob: BackupBlobRecord) async throws {}
}

private struct EmptyStateStore: BackupStateStoring {
    func load() throws -> BackupState { BackupState() }
    func save(_ state: BackupState) throws {}
}
