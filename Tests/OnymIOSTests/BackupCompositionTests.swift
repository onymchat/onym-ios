import CryptoKit
import XCTest
@testable import OnymBackup

/// Composition and restore, with one test that matters more than the
/// rest: nothing derived from the recovery phrase may appear in a
/// plaintext archive.
final class BackupCompositionTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The §16.1 guard. A snapshot that leaked seed material would hand
    /// an operator the ability to open every snapshot it ever stores,
    /// and the failure would be invisible from the outside.
    func testArchiveContainsNoSeedMaterial() async throws {
        let dir = try makeDirectory()
        let mnemonic = "legal winner thank year wave sausage worth useful legal winner thank yellow"
        let source = StubSource(
            groups: [Self.group(name: "Weekend plans")],
            messages: [Self.message(body: "see you at six")]
        )
        let composer = BackupComposer(
            source: source, mediaPolicy: .descriptorsOnly, workingDirectory: dir)

        let seed = Data(repeating: 0x11, count: 64)
        let material = BackupKeys.material(seed: seed, componentId: "onym:component:op")
        let snapshot = try await composer.compose(
            keyMaterial: material, acceptedTermsId: "sha256:" + String(repeating: "a", count: 64))

        // Open it back to plaintext and scan the actual archive bytes.
        let plain = dir.appending(path: "plain")
        try BackupOpener.open(
            sealedURL: snapshot.sealedBytesURL, to: plain,
            reference: snapshot.snapshotReference, archiveRoot: material.archiveRoot)
        let bytes = try Data(contentsOf: plain)

        XCTAssertFalse(bytes.contains(seed), "raw seed bytes are in the archive")
        for word in mnemonic.split(separator: " ") {
            XCTAssertFalse(
                bytes.range(of: Data(word.utf8)) != nil && word.count > 5,
                "mnemonic word \"\(word)\" appears in the archive")
        }
        XCTAssertNil(
            bytes.range(of: material.accessSigningKey.rawRepresentation),
            "the access signing key is in the archive")
        XCTAssertNil(
            bytes.range(of: material.archiveRoot.withUnsafeBytes { Data($0) }),
            "the archive root key is in the archive")

        // Sanity: the archive really does contain the payload, so the
        // assertions above are not passing on an empty file.
        XCTAssertNotNil(bytes.range(of: Data("Weekend plans".utf8)))
    }

    func testComposeRestoreRoundTrip() async throws {
        let dir = try makeDirectory()
        let source = StubSource(
            groups: [Self.group(name: "Book club")],
            messages: [Self.message(body: "chapter four")])
        let composer = BackupComposer(
            source: source, mediaPolicy: .descriptorsOnly, workingDirectory: dir)
        let material = BackupKeys.material(
            seed: Data(repeating: 0x22, count: 64), componentId: "onym:component:op")
        let snapshot = try await composer.compose(
            keyMaterial: material, acceptedTermsId: "sha256:" + String(repeating: "b", count: 64))

        let sink = StubSink()
        let summary = try await BackupRestorer(sink: sink).restore(
            sealedURL: snapshot.sealedBytesURL,
            reference: snapshot.snapshotReference,
            keyMaterial: material,
            workingDirectory: dir)

        XCTAssertEqual(summary.groups, 1)
        XCTAssertEqual(summary.messages, 1)
        let restored = await sink.groups
        XCTAssertEqual(restored.first?.name, "Book club")
    }

    /// The plaintext archive is the one artefact on disk readable
    /// without the seed. It must not survive composition.
    func testPlaintextArchiveIsRemovedAfterSealing() async throws {
        let dir = try makeDirectory()
        let composer = BackupComposer(
            source: StubSource(groups: [Self.group(name: "x")], messages: []),
            mediaPolicy: .descriptorsOnly, workingDirectory: dir)
        let material = BackupKeys.material(
            seed: Data(repeating: 0x33, count: 64), componentId: "onym:component:op")
        let snapshot = try await composer.compose(
            keyMaterial: material, acceptedTermsId: "sha256:" + String(repeating: "c", count: 64))

        let leftover = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftover, [snapshot.sealedBytesURL.lastPathComponent],
                       "composition left plaintext behind: \(leftover)")
    }

    func testBlobsAreVerifiedAgainstTheirAddress() async throws {
        let dir = try makeDirectory()
        let real = Data("real bytes".utf8)
        let address = SHA256.hash(data: real).map { String(format: "%02x", $0) }.joined()
        let attachment = Data(#"{"sha256":"\#(address)","encKey":"k"}"#.utf8)

        // The store answers with something that is not what it claims.
        let source = StubSource(
            groups: [Self.group(name: "g")],
            messages: [Self.message(body: "with media", imageJSON: attachment)],
            blobs: [address: Data("different bytes".utf8)])
        let composer = BackupComposer(
            source: source, mediaPolicy: .includeCiphertext, workingDirectory: dir)
        let material = BackupKeys.material(
            seed: Data(repeating: 0x44, count: 64), componentId: "onym:component:op")
        let snapshot = try await composer.compose(
            keyMaterial: material, acceptedTermsId: "sha256:" + String(repeating: "d", count: 64))

        let sink = StubSink()
        let summary = try await BackupRestorer(sink: sink).restore(
            sealedURL: snapshot.sealedBytesURL, reference: snapshot.snapshotReference,
            keyMaterial: material, workingDirectory: dir)
        XCTAssertEqual(summary.blobs, 0, "a mis-addressed blob was included")
        XCTAssertEqual(summary.unresolvedBlobs, [address], "the gap was not reported")
    }

    // MARK: - Fixtures

    private static func group(name: String) -> BackupGroupRecord {
        BackupGroupRecord(
            id: String(repeating: "a", count: 64), ownerIdentityID: UUID().uuidString,
            name: name, groupSecret: Data(repeating: 0xEE, count: 32), createdAt: Date(),
            membersJSON: Data("[]".utf8), memberProfilesJSON: Data("{}".utf8),
            epoch: 0, salt: Data(repeating: 1, count: 32), commitment: nil,
            tierRaw: 0, groupTypeRaw: "tyranny", adminPubkeyHex: nil,
            adminEd25519PubkeyHex: nil, isPublishedOnChain: false,
            avatarJPEG: nil, lastReadAt: nil, invitationMessage: nil)
    }

    private static func message(body: String, imageJSON: Data? = nil) -> BackupMessageRecord {
        BackupMessageRecord(
            id: UUID().uuidString, groupID: String(repeating: "a", count: 64),
            ownerIdentityID: UUID().uuidString, senderBlsPubkeyHex: "ab",
            body: body, sentAt: Date(), directionRaw: "outgoing", statusRaw: "sent",
            groupTypeRaw: "tyranny", replyToMessageID: nil, failureReasonRaw: nil,
            moderationAuthenticityProof: nil, imageAttachmentJSON: imageJSON,
            videoAttachmentJSON: nil, albumAttachmentsJSON: nil,
            voiceAttachmentJSON: nil, systemEventJSON: nil)
    }
}

private struct StubSource: BackupSourceProviding {
    var groupRecords: [BackupGroupRecord] = []
    var messageRecords: [BackupMessageRecord] = []
    var blobs: [String: Data] = [:]

    init(groups: [BackupGroupRecord], messages: [BackupMessageRecord], blobs: [String: Data] = [:]) {
        self.groupRecords = groups
        self.messageRecords = messages
        self.blobs = blobs
    }

    func identityCount() async -> Int { 1 }
    func groups() async throws -> [BackupGroupRecord] { groupRecords }
    func messages(groupID: String, ownerIdentityID: String) async throws -> [BackupMessageRecord] {
        messageRecords
    }
    func invitations() async throws -> [BackupInvitationRecord] { [] }
    func consents() async throws -> [BackupConsentRecord] { [] }
    func blobCiphertext(sha256: String) async throws -> Data? { blobs[sha256] }
}

private actor StubSink: BackupSinkProviding {
    var groups: [BackupGroupRecord] = []
    var messages: [BackupMessageRecord] = []
    var blobs: [BackupBlobRecord] = []

    func restore(groups: [BackupGroupRecord]) async throws { self.groups = groups }
    func restore(messages: [BackupMessageRecord]) async throws { self.messages = messages }
    func restore(invitations: [BackupInvitationRecord]) async throws {}
    func restore(consents: [BackupConsentRecord]) async throws {}
    func restore(blob: BackupBlobRecord) async throws { blobs.append(blob) }
}
