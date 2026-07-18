import CryptoKit
import UIKit
import XCTest
@testable import OnymIOS

/// In-memory `BlossomClient` fake for the send tests — records uploaded
/// blobs by their sha256 and can be flipped to fail.
actor FakeBlossomClient: BlossomClient {
    private var blobs: [String: Data] = [:]
    private var failing = false

    var storedSha256s: [String] { Array(blobs.keys) }

    func setFailing(_ value: Bool) { failing = value }

    func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor {
        if failing { throw BlossomError.badStatus(500) }
        let sha = ChatImageCrypto.sha256Hex(blob)
        blobs[sha] = blob
        return BlobDescriptor(sha256: sha, url: "https://blossom.test/\(sha)", size: blob.count)
    }

    func download(sha256: String) async throws -> Data {
        guard let data = blobs[sha256] else { throw BlossomError.badStatus(404) }
        return data
    }
}

/// Behavioral tests for `SendMessageInteractor`. Uses a real
/// `IdentityRepository` (test-namespaced keychain, in-memory
/// selection) so the `sealInvitation` path is exercised end-to-end;
/// the transport is a `RecordingInboxTransport` that lets each test
/// control whether sends "succeed" (acceptedBy >= 1) or "fail"
/// (acceptedBy == 0).
@MainActor
final class SendMessageInteractorTests: XCTestCase {

    private var identity: IdentityRepository!
    private var transport: RecordingInboxTransport!
    private var groups: GroupRepository!
    private var messages: MessageRepository!
    private var blossom: FakeBlossomClient!
    private var interactor: SendMessageInteractor!

    // Set after `bootstrap()`. The active identity's BLS hex —
    // matches the `senderBlsPubkeyHex` the interactor will mint.
    private var myBlsHex: String!
    private var myInbox: Data!
    private var mySendingPubkey: Data!
    private var currentIdentityID: IdentityID!

    override func setUp() async throws {
        try await super.setUp()

        let keychain = IdentityKeychainStore(
            testNamespace: "send-message-\(UUID().uuidString)"
        )
        identity = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory()
        )
        // Real BIP39 vector so we get real BLS + Ed25519 keys.
        _ = try await identity.restore(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )
        let active = await identity.currentIdentity()!
        myBlsHex = active.blsPublicKey.map { String(format: "%02x", $0) }.joined()
        myInbox = active.inboxPublicKey
        mySendingPubkey = active.stellarPublicKey
        currentIdentityID = await identity.currentSelectedID()!

        transport = RecordingInboxTransport()
        groups = GroupRepository(
            store: SwiftDataGroupStore.inMemory(),
            currentIdentityID: currentIdentityID
        )
        messages = MessageRepository(store: SwiftDataMessageStore.inMemory())
        blossom = FakeBlossomClient()

        interactor = SendMessageInteractor(
            identity: identity,
            inboxTransport: transport,
            messageRepository: messages,
            groupRepository: groups,
            blossomClient: blossom,
            blossomServerURL: "https://blossom.test"
        )
    }

    override func tearDown() async throws {
        identity = nil
        transport = nil
        groups = nil
        messages = nil
        interactor = nil
        myBlsHex = nil
        myInbox = nil
        mySendingPubkey = nil
        currentIdentityID = nil
        try await super.tearDown()
    }

    // MARK: - Image send

    func test_sendImage_uploadsBlob_andPersistsAttachment() async throws {
        let groupID = await seedGroupWithTwoPeers()
        let imageData = Self.makeJPEG()

        let result = try await interactor.sendImage(
            groupID: groupID, imageData: imageData, caption: "pic"
        )
        XCTAssertEqual(result.status, .sent)
        XCTAssertEqual(result.body, "pic")
        let attachment = try XCTUnwrap(result.imageAttachment)
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.server, "https://blossom.test")
        XCTAssertEqual(attachment.encKey.count, 32)
        XCTAssertFalse(attachment.blurhash.isEmpty)

        // The ciphertext blob was uploaded under its sha256.
        let uploaded = await blossom.storedSha256s
        XCTAssertTrue(uploaded.contains(attachment.sha256))

        // Fanned out to the two peers, and persisted with the attachment.
        let sends = await transport.recordedSends
        XCTAssertEqual(sends.count, 2)
        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].imageAttachment?.sha256, attachment.sha256)
    }

    func test_sendImage_uploadFailure_throws_andPersistsNothing() async throws {
        let groupID = await seedGroupWithTwoPeers()
        await blossom.setFailing(true)
        do {
            _ = try await interactor.sendImage(groupID: groupID, imageData: Self.makeJPEG())
            XCTFail("expected upload failure")
        } catch {
            // expected
        }
        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertTrue(stored.isEmpty, "a failed upload must not leave a dangling bubble")
    }

    nonisolated private static func makeJPEG() -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return img.jpegData(compressionQuality: 0.8)!
    }

    // MARK: - Video send

    /// Canned encoding so the test doesn't run AVFoundation transcoding:
    /// a real poster (encoded from a test JPEG) + placeholder MP4 bytes.
    /// `nonisolated` so it can be called from the interactor's off-main
    /// `@Sendable` encoder closure.
    nonisolated private static func cannedVideoEncoded(mp4: Data = Data("mp4".utf8)) -> ChatVideoEncoder.Encoded {
        let poster = ChatImageEncoder.encode(fromImageData: makeJPEG())!
        return ChatVideoEncoder.Encoded(
            mp4: mp4, width: 1280, height: 720, durationSeconds: 4, poster: poster
        )
    }

    private func makeVideoInteractor(
        encoder: @escaping @Sendable (URL) async -> ChatVideoEncoder.Encoded?
    ) -> SendMessageInteractor {
        SendMessageInteractor(
            identity: identity,
            inboxTransport: transport,
            messageRepository: messages,
            groupRepository: groups,
            blossomClient: blossom,
            blossomServerURL: "https://blossom.test",
            videoEncoder: encoder
        )
    }

    func test_sendVideo_uploadsPosterAndVideoBlobs_andPersistsAttachment() async throws {
        let groupID = await seedGroupWithTwoPeers()
        let sut = makeVideoInteractor { _ in Self.cannedVideoEncoded() }

        let result = try await sut.sendVideo(
            groupID: groupID, videoURL: Self.dummyVideoURL(), caption: "clip"
        )

        XCTAssertEqual(result.status, .sent)
        XCTAssertEqual(result.body, "clip")
        let video = try XCTUnwrap(result.videoAttachment)
        XCTAssertEqual(video.mimeType, "video/mp4")
        XCTAssertEqual(video.server, "https://blossom.test")
        XCTAssertEqual(video.encKey.count, 32)
        XCTAssertEqual(video.durationSeconds, 4)
        XCTAssertEqual(video.width, 1280)
        // Poster is its own encrypted blob with its own key + blurhash.
        XCTAssertEqual(video.poster.mimeType, "image/jpeg")
        XCTAssertEqual(video.poster.encKey.count, 32)
        XCTAssertNotEqual(video.poster.sha256, video.sha256)
        XCTAssertFalse(video.poster.blurhash.isEmpty)

        // Both blobs (poster + video) were uploaded under their sha256s.
        let uploaded = await blossom.storedSha256s
        XCTAssertTrue(uploaded.contains(video.sha256))
        XCTAssertTrue(uploaded.contains(video.poster.sha256))

        // Fanned out to the two peers, and persisted with the video.
        let sends = await transport.recordedSends
        XCTAssertEqual(sends.count, 2)
        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].videoAttachment?.sha256, video.sha256)
    }

    func test_sendVideo_encodeFailure_throws_andPersistsNothing() async throws {
        let groupID = await seedGroupWithTwoPeers()
        let sut = makeVideoInteractor { _ in nil }
        do {
            _ = try await sut.sendVideo(groupID: groupID, videoURL: Self.dummyVideoURL())
            XCTFail("expected encode failure")
        } catch SendMessageInteractor.SendError.videoEncodeFailed {
            // expected
        }
        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertTrue(stored.isEmpty)
    }

    func test_sendVideo_uploadFailure_throws_andPersistsNothing() async throws {
        let groupID = await seedGroupWithTwoPeers()
        await blossom.setFailing(true)
        let sut = makeVideoInteractor { _ in Self.cannedVideoEncoded() }
        do {
            _ = try await sut.sendVideo(groupID: groupID, videoURL: Self.dummyVideoURL())
            XCTFail("expected upload failure")
        } catch SendMessageInteractor.SendError.videoUploadFailed {
            // expected
        }
        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertTrue(stored.isEmpty, "a failed upload must not leave a dangling bubble")
    }

    func test_sendVideo_oversizeBlob_throwsVideoTooLarge() async throws {
        let groupID = await seedGroupWithTwoPeers()
        // A plaintext just over the cap → the encrypted blob also exceeds it.
        let huge = Data(count: SendMessageInteractor.maxUploadBytes + 1)
        let sut = makeVideoInteractor { _ in Self.cannedVideoEncoded(mp4: huge) }
        do {
            _ = try await sut.sendVideo(groupID: groupID, videoURL: Self.dummyVideoURL())
            XCTFail("expected too-large rejection")
        } catch SendMessageInteractor.SendError.videoTooLarge {
            // expected
        }
        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertTrue(stored.isEmpty)
    }

    private static func dummyVideoURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-video").appendingPathExtension("mov")
    }

    // MARK: - Happy path

    func test_send_persistsAsSent_andFansOutToOtherMembers() async throws {
        // Group has me + two peers.
        let groupID = await seedGroupWithTwoPeers()

        let result = try await interactor.send(groupID: groupID, body: "hello")
        XCTAssertEqual(result.status, .sent)
        XCTAssertEqual(result.direction, .outgoing)
        XCTAssertEqual(result.body, "hello")
        XCTAssertEqual(result.senderBlsPubkeyHex, myBlsHex)

        let sends = await transport.recordedSends
        XCTAssertEqual(sends.count, 2,
                       "must fan out to N-1 members (skipping self)")

        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].status, .sent)
    }

    func test_send_skipsSelfRecipient() async throws {
        // Even though our profile is in memberProfiles, we must not
        // send a copy to our own inbox.
        let groupID = await seedGroupWithTwoPeers()

        _ = try await interactor.send(groupID: groupID, body: "hi")

        let sentInboxes = await transport.recordedSends.map(\.inbox)
        // Inbox tag derives from the recipient's inboxPublicKey.
        // Self's tag must not appear.
        let myTag = Self.inboxTag(from: myInbox)
        XCTAssertFalse(
            sentInboxes.contains(TransportInboxID(rawValue: myTag)),
            "must not send to self's inbox"
        )
    }

    func test_send_zeroOtherMembers_persistsAsSentWithNoFanout() async throws {
        // Group has only me — no one to send to.
        let groupID = "11".repeated(32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [
                myBlsHex: MemberProfile(
                    alias: "Me",
                    inboxPublicKey: myInbox,
                    sendingPubkey: mySendingPubkey
                )
            ]
        )

        let result = try await interactor.send(groupID: groupID, body: "lonely")
        XCTAssertEqual(result.status, .sent)

        let sends = await transport.recordedSends
        XCTAssertTrue(sends.isEmpty,
                      "no recipients → no transport sends")

        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertEqual(stored.count, 1)
    }

    func test_send_withReplyRef_carriesTargetOntoMessage() async throws {
        let groupID = await seedGroupWithTwoPeers()
        let target = UUID()

        let result = try await interactor.send(
            groupID: groupID,
            body: "agreed",
            replyToMessageID: target
        )
        XCTAssertEqual(result.replyToMessageID, target,
                       "the returned message must carry the reply target")

        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertEqual(stored.first?.replyToMessageID, target,
                       "the optimistically-inserted row must carry the reply target")
    }

    func test_send_noReplyRef_isNil() async throws {
        let groupID = await seedGroupWithTwoPeers()
        let result = try await interactor.send(groupID: groupID, body: "plain")
        XCTAssertNil(result.replyToMessageID)
    }

    // MARK: - Status transitions

    func test_send_allRelaysReject_marksFailed() async throws {
        let groupID = await seedGroupWithTwoPeers()
        await transport.setAcceptedBy(0)

        let result = try await interactor.send(groupID: groupID, body: "hi")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureReason, .relayRejected,
                       "zero acceptances without a throw is an explicit relay refusal")

        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertEqual(stored[0].status, .failed)
        XCTAssertEqual(stored[0].failureReason, .relayRejected,
                       "the persisted row must carry the reason so the UI can explain the red bang")
    }

    // MARK: - Failure reasons (why the red bang happened)

    func test_send_transportNotConnected_reasonIsNoRelayConnection() async throws {
        let groupID = await seedGroupWithTwoPeers()
        await transport.setBehavior(.alwaysThrows(.notConnected))

        let result = try await interactor.send(groupID: groupID, body: "hi")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureReason, .noRelayConnection)
    }

    func test_send_tlsFailure_reasonIsSecureConnectionFailed() async throws {
        // The expired-relay-certificate scenario: every relay socket
        // dies in the TLS handshake, so the transport reports
        // `.unreachable(.secureConnectionFailed)`.
        let groupID = await seedGroupWithTwoPeers()
        await transport.setBehavior(.alwaysThrows(.unreachable(.secureConnectionFailed)))

        let result = try await interactor.send(groupID: groupID, body: "hi")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failureReason, .secureConnectionFailed)
    }

    func test_send_offline_reasonIsOffline() async throws {
        let groupID = await seedGroupWithTwoPeers()
        await transport.setBehavior(.alwaysThrows(.unreachable(.notConnectedToInternet)))

        let result = try await interactor.send(groupID: groupID, body: "hi")
        XCTAssertEqual(result.failureReason, .offline)
    }

    func test_send_otherNetworkError_reasonIsRelayUnreachable() async throws {
        let groupID = await seedGroupWithTwoPeers()
        await transport.setBehavior(.alwaysThrows(.unreachable(.timedOut)))

        let result = try await interactor.send(groupID: groupID, body: "hi")
        XCTAssertEqual(result.failureReason, .relayUnreachable)
    }

    func test_send_success_hasNoFailureReason() async throws {
        let groupID = await seedGroupWithTwoPeers()
        let result = try await interactor.send(groupID: groupID, body: "hi")
        XCTAssertEqual(result.status, .sent)
        XCTAssertNil(result.failureReason)
    }

    func test_send_oneRelayAccepts_marksSent_bestEffort() async throws {
        // First send succeeds, second throws. With best-effort
        // semantics, status is `.sent` because at least one envelope
        // landed.
        let groupID = await seedGroupWithTwoPeers()
        await transport.setBehavior(.firstSucceedsThenThrows)

        let result = try await interactor.send(groupID: groupID, body: "hi")
        XCTAssertEqual(result.status, .sent,
                       "best-effort: any successful relay marks the message sent")
    }

    // MARK: - Error paths

    func test_send_unknownGroup_throws() async throws {
        await assertThrows(SendMessageInteractor.SendError.unknownGroup) {
            try await self.interactor.send(
                groupID: "ff".repeated(32),
                body: "hi"
            )
        }
    }

    func test_send_notAMember_throws() async throws {
        // Seed a group where the current identity is NOT in
        // memberProfiles.
        let groupID = "22".repeated(32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [
                "ab".repeated(48): MemberProfile(
                    alias: "Other",
                    inboxPublicKey: Data(repeating: 0xAB, count: 32),
                    sendingPubkey: Data(repeating: 0xCD, count: 32)
                )
            ]
        )

        await assertThrows(SendMessageInteractor.SendError.senderNotAMember) {
            try await self.interactor.send(groupID: groupID, body: "hi")
        }
    }

    func test_send_emptyBody_throws() async throws {
        let groupID = await seedGroupWithTwoPeers()
        await assertThrows(SendMessageInteractor.SendError.emptyBody) {
            try await self.interactor.send(groupID: groupID, body: "")
        }
    }

    // MARK: - Retry (PR 9)

    func test_retry_failedMessage_flipsToSentOnSuccess() async throws {
        let groupID = await seedGroupWithTwoPeers()
        // Drive an initial send to .failed by rejecting all relays.
        await transport.setAcceptedBy(0)
        let original = try await interactor.send(groupID: groupID, body: "retry me")
        XCTAssertEqual(original.status, .failed)
        await transport.clearRecords()

        // Now flip transport back to success and retry.
        await transport.setAcceptedBy(1)
        await interactor.retry(groupID: groupID, messageID: original.id)

        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertEqual(stored.count, 1, "retry must not duplicate the row")
        XCTAssertEqual(stored[0].id, original.id, "retry must reuse the same message id")
        XCTAssertEqual(stored[0].status, .sent)
        XCTAssertNil(stored[0].failureReason,
                     "a successful retry must clear the stale failure explanation")

        let sends = await transport.recordedSends
        XCTAssertEqual(sends.count, 2, "retry must re-fan out to both peers")
    }

    func test_retry_failedMessage_staysFailedIfRelaysStillReject() async throws {
        let groupID = await seedGroupWithTwoPeers()
        await transport.setAcceptedBy(0)
        let original = try await interactor.send(groupID: groupID, body: "still no luck")
        XCTAssertEqual(original.status, .failed)

        await interactor.retry(groupID: groupID, messageID: original.id)

        let stored = await messages.currentMessages(groupID: groupID, owner: currentIdentityID)
        XCTAssertEqual(stored[0].status, .failed)
    }

    func test_retry_unknownMessage_isNoOp() async throws {
        let groupID = await seedGroupWithTwoPeers()
        await interactor.retry(groupID: groupID, messageID: UUID())
        let sends = await transport.recordedSends
        XCTAssertTrue(sends.isEmpty,
                      "retrying an unknown messageID must not perform any sends")
    }

    func test_retry_nonFailedMessage_isNoOp() async throws {
        // A .sent message must not re-fan out — that would
        // double-deliver. Retry is for .failed rows only.
        let groupID = await seedGroupWithTwoPeers()
        let sent = try await interactor.send(groupID: groupID, body: "already delivered")
        XCTAssertEqual(sent.status, .sent)
        await transport.clearRecords()

        await interactor.retry(groupID: groupID, messageID: sent.id)
        let sends = await transport.recordedSends
        XCTAssertTrue(sends.isEmpty,
                      "retrying a .sent message must not double-deliver")
    }

    // MARK: - Helpers

    private func seedGroupWithTwoPeers() async -> String {
        let groupID = "44".repeated(32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [
                myBlsHex: MemberProfile(
                    alias: "Me",
                    inboxPublicKey: myInbox,
                    sendingPubkey: mySendingPubkey
                ),
                "aa".repeated(48): MemberProfile(
                    alias: "Alice",
                    inboxPublicKey: Data(repeating: 0xA1, count: 32),
                    sendingPubkey: Data(repeating: 0xE1, count: 32)
                ),
                "bb".repeated(48): MemberProfile(
                    alias: "Bob",
                    inboxPublicKey: Data(repeating: 0xB1, count: 32),
                    sendingPubkey: Data(repeating: 0xE2, count: 32)
                ),
            ]
        )
        return groupID
    }

    private func seedGroup(
        groupID: String,
        memberProfiles: [String: MemberProfile]
    ) async {
        let group = ChatGroup(
            id: groupID,
            ownerIdentityID: currentIdentityID,
            name: "Group",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            members: [],
            memberProfiles: memberProfiles,
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: myBlsHex,
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: true
        )
        _ = await groups.insert(group)
    }

    private func assertThrows<E: Error & Equatable>(
        _ expected: E,
        _ block: @escaping () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await block()
            XCTFail("expected throw of \(expected)", file: file, line: line)
        } catch let error as E {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private static func inboxTag(from inboxPublicKey: Data) -> String {
        // Same derivation as `SendMessageInteractor.inboxTag(from:)`.
        let prefix = Data("sep-inbox-v1".utf8) + inboxPublicKey
        let digest = SHA256.hash(data: prefix)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}

/// Recording transport with a configurable success behavior. Each
/// test calls `setAcceptedBy` or `setBehavior` before driving the
/// interactor; the recorded sends are available via `recordedSends`.
private actor RecordingInboxTransport: InboxTransport {
    struct Record: Sendable {
        let payload: Data
        let inbox: TransportInboxID
    }

    enum Behavior: Sendable {
        case constantAcceptedBy(Int)
        case firstSucceedsThenThrows
        case alwaysThrows(TransportError)
    }

    private(set) var recordedSends: [Record] = []
    private var behavior: Behavior = .constantAcceptedBy(1)
    private var sendCount = 0

    func setAcceptedBy(_ count: Int) {
        behavior = .constantAcceptedBy(count)
    }

    func setBehavior(_ b: Behavior) {
        behavior = b
    }

    func clearRecords() {
        recordedSends.removeAll()
        sendCount = 0
    }

    func connect(to endpoints: [TransportEndpoint]) async {}
    func disconnect() async {}

    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        recordedSends.append(Record(payload: payload, inbox: inbox))
        sendCount += 1
        switch behavior {
        case .constantAcceptedBy(let n):
            return PublishReceipt(messageID: "fake-\(UUID().uuidString)", acceptedBy: n)
        case .firstSucceedsThenThrows:
            if sendCount == 1 {
                return PublishReceipt(messageID: "fake-\(UUID().uuidString)", acceptedBy: 1)
            }
            throw NSError(domain: "test", code: 1)
        case .alwaysThrows(let error):
            throw error
        }
    }

    nonisolated func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        AsyncStream { _ in }
    }
    func unsubscribe(inbox: TransportInboxID) async {}
}
