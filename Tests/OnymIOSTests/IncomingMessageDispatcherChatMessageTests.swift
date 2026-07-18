import XCTest
@testable import OnymIOS

/// Tests for the chat-message branch of `IncomingMessageDispatcher`.
/// Kept separate from the announcement / invitation paths so the
/// trust-check surface is easy to scan: every test seeds a group +
/// member roster, then asserts whether a chat message envelope
/// lands in `MessageRepository` or gets dropped.
@MainActor
final class IncomingMessageDispatcherChatMessageTests: XCTestCase {

    private var groups: GroupRepository!
    private var invitations: IncomingInvitationsRepository!
    private var messages: MessageRepository!
    private var chainState: DispatcherStubChainState!
    private var owner: IdentityID!

    // Sender identity. BLS pubkey is the roster key; Ed25519 is the
    // envelope's verified signer.
    private let senderBlsHex = "11".repeated(48)
    private let senderEd25519 = Data(repeating: 0xE1, count: 32)
    private let senderInbox = Data(repeating: 0x11, count: 32)

    private let groupIDBytes = Data(repeating: 0x42, count: 32)
    private var groupIDHex: String { groupIDBytes.map { String(format: "%02x", $0) }.joined() }

    override func setUp() async throws {
        try await super.setUp()
        groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        invitations = IncomingInvitationsRepository(store: SwiftDataInvitationStore.inMemory())
        messages = MessageRepository(store: SwiftDataMessageStore.inMemory())
        chainState = DispatcherStubChainState()
        owner = IdentityID()
        await groups.setCurrentIdentity(owner)

        // Seed a Tyranny group with the sender as a member.
        let group = ChatGroup(
            id: groupIDHex,
            ownerIdentityID: owner,
            name: "Family",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            members: [],
            memberProfiles: [
                senderBlsHex: MemberProfile(
                    alias: "Alice",
                    inboxPublicKey: senderInbox,
                    sendingPubkey: senderEd25519
                )
            ],
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: nil,
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: true
        )
        _ = await groups.insert(group)
    }

    override func tearDown() async throws {
        groups = nil
        invitations = nil
        messages = nil
        chainState = nil
        owner = nil
        try await super.tearDown()
    }

    // MARK: - Happy path

    func test_chatMessage_validSignature_persistsAsIncoming() async throws {
        let payload = makePayload(body: "hello, group")
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: senderEd25519
        )

        await dispatcher.dispatch(
            messageID: "msg-1",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].body, "hello, group")
        XCTAssertEqual(stored[0].direction, .incoming)
        XCTAssertEqual(stored[0].status, .received)
        XCTAssertEqual(stored[0].senderBlsPubkeyHex, senderBlsHex)
        XCTAssertEqual(stored[0].groupType, .tyranny)
        XCTAssertNil(stored[0].replyToMessageID)
    }

    func test_chatMessage_withReplyRef_persistsTargetID() async throws {
        let target = UUID()
        let payload = makePayload(body: "agreed", replyToMessageID: target)
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: senderEd25519
        )

        await dispatcher.dispatch(
            messageID: "msg-reply",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertEqual(stored.first?.replyToMessageID, target,
                       "an inbound reply must carry its target id onto the persisted message")
    }

    // MARK: - Drop paths

    func test_chatMessage_unknownGroup_drops() async throws {
        // Payload claims a group we don't have locally.
        let payload = makePayload(
            body: "hi",
            groupIDBytes: Data(repeating: 0xFF, count: 32)
        )
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: senderEd25519
        )

        await dispatcher.dispatch(
            messageID: "msg-1",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertTrue(stored.isEmpty,
                      "message for unknown group must not be persisted")
    }

    func test_chatMessage_senderNotInRoster_drops() async throws {
        // Sender BLS hex doesn't appear in the group's memberProfiles.
        let payload = makePayload(
            body: "hi",
            senderBlsHex: "ff".repeated(48)
        )
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: senderEd25519
        )

        await dispatcher.dispatch(
            messageID: "msg-1",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertTrue(stored.isEmpty,
                      "message from non-member must not be persisted")
    }

    func test_chatMessage_signatureMismatch_drops() async throws {
        // Payload claims to be from Alice (in the roster) but the
        // envelope is signed by a different Ed25519 — i.e. Bob is
        // trying to forge Alice's identity.
        let payload = makePayload(body: "i am alice (lying)")
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: Data(repeating: 0xBB, count: 32)  // not Alice
        )

        await dispatcher.dispatch(
            messageID: "msg-1",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertTrue(stored.isEmpty,
                      "envelope signed by wrong Ed25519 must be dropped (insider-spoof defense)")
    }

    func test_chatMessage_missingEnvelopeSignature_drops() async throws {
        // Envelope decrypter returns the plaintext but no
        // senderEd25519PublicKey — anonymous chat messages are not
        // part of the v1 trust model.
        let payload = makePayload(body: "hi")
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: nil
        )

        await dispatcher.dispatch(
            messageID: "msg-1",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertTrue(stored.isEmpty,
                      "envelope without a signature must be dropped")
    }

    func test_chatMessage_wrongOwnerIdentity_drops() async throws {
        // Group is owned by `self.owner` but the dispatch call uses a
        // different identity. This shouldn't happen in production
        // (inbox routing is per-identity) but guards against a
        // delivery mistake.
        let otherIdentity = IdentityID()
        let payload = makePayload(body: "hi")
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: senderEd25519
        )

        await dispatcher.dispatch(
            messageID: "msg-1",
            ownerIdentityID: otherIdentity,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertTrue(stored.isEmpty)
    }

    func test_chatMessage_persistsForNonActiveIdentity() async throws {
        // Multi-identity correctness: each identity has its own inbox
        // subscription via `InboxFanoutInteractor`, and the dispatcher
        // takes `ownerIdentityID` as a parameter (per inbox), not from
        // an "active identity" global. Messages addressed to a
        // non-active identity must still persist so they're visible
        // when the user switches identities.
        let secondIdentity = IdentityID()
        await groups.setCurrentIdentity(owner)  // first identity stays "active"

        // Seed a separate Tyranny group owned by the second identity.
        let secondGroupBytes = Data(repeating: 0x99, count: 32)
        let secondGroupHex = secondGroupBytes
            .map { String(format: "%02x", $0) }.joined()
        let secondSenderBlsHex = "22".repeated(48)
        let secondSenderEd25519 = Data(repeating: 0xE2, count: 32)
        let secondGroup = ChatGroup(
            id: secondGroupHex,
            ownerIdentityID: secondIdentity,
            name: "Work",
            groupSecret: Data(repeating: 0x77, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            members: [],
            memberProfiles: [
                secondSenderBlsHex: MemberProfile(
                    alias: "Eve",
                    inboxPublicKey: Data(repeating: 0x22, count: 32),
                    sendingPubkey: secondSenderEd25519
                )
            ],
            epoch: 0,
            salt: Data(repeating: 0x88, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: nil,
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: true
        )
        _ = await groups.insert(secondGroup)

        // Dispatch a message addressed to the non-active identity.
        let payload = ChatMessagePayload(
            version: 1,
            messageID: UUID(),
            groupID: secondGroupBytes,
            senderBlsPubkeyHex: secondSenderBlsHex,
            sentAtMillis: 1_700_000_500_000,
            replyToMessageID: nil,
            variant: .tyranny(body: "for the second identity")
        )
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: secondSenderEd25519
        )
        await dispatcher.dispatch(
            messageID: "msg-multi",
            ownerIdentityID: secondIdentity,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        // First identity's group sees nothing.
        let firstStored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertTrue(firstStored.isEmpty)

        // Second identity's group has the message even though it
        // wasn't the active identity at delivery time.
        let secondStored = await messages.currentMessages(groupID: secondGroupHex, owner: secondIdentity)
        XCTAssertEqual(secondStored.count, 1)
        XCTAssertEqual(secondStored[0].body, "for the second identity")
        XCTAssertEqual(secondStored[0].ownerIdentityID, secondIdentity)
    }

    func test_chatMessage_duplicateMessageID_idempotent() async throws {
        let payload = makePayload(body: "hi", messageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let envelopeBytes = Data("envelope".utf8)
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: senderEd25519
        )

        // Same message delivered twice (Nostr re-delivery, etc.).
        await dispatcher.dispatch(
            messageID: "msg-1",
            ownerIdentityID: owner,
            payload: envelopeBytes,
            receivedAt: Date()
        )
        await dispatcher.dispatch(
            messageID: "msg-1-retry",
            ownerIdentityID: owner,
            payload: envelopeBytes,
            receivedAt: Date()
        )

        let stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertEqual(stored.count, 1,
                       "second delivery of the same message id must be a no-op")
    }

    // MARK: - Helpers

    private func makePayload(
        body: String,
        groupIDBytes: Data? = nil,
        senderBlsHex: String? = nil,
        messageID: UUID = UUID(),
        replyToMessageID: UUID? = nil
    ) -> ChatMessagePayload {
        ChatMessagePayload(
            version: 1,
            messageID: messageID,
            groupID: groupIDBytes ?? self.groupIDBytes,
            senderBlsPubkeyHex: senderBlsHex ?? self.senderBlsHex,
            sentAtMillis: 1_700_000_000_000,
            replyToMessageID: replyToMessageID,
            variant: .tyranny(body: body)
        )
    }

    private func makeDispatcher(
        plaintext: Data,
        envelopeSigner: Data?,
        receiptSender: any ChatReceiptSending = NoopChatReceiptSender(),
        readReceiptsEnabled: @escaping @Sendable () -> Bool = { true }
    ) -> IncomingMessageDispatcher {
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: envelopeSigner
        )
        return IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: messages,
            receiptSender: receiptSender,
            readReceiptsEnabled: readReceiptsEnabled
        )
    }

    // MARK: - Receipts

    func test_incomingChatMessage_shipsDeliveredReceiptToSender() async throws {
        let payload = makePayload(body: "hi")
        let spy = SpyChatReceiptSender()
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(payload),
            envelopeSigner: senderEd25519,
            receiptSender: spy
        )
        await dispatcher.dispatch(
            messageID: "msg-1",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let sends = await spy.sends
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.kind, .delivered)
        XCTAssertEqual(sends.first?.messageIDs, [payload.messageID])
        XCTAssertEqual(sends.first?.recipientInboxKey, senderInbox,
                       "delivered receipt must be addressed to the message sender's inbox")
    }

    func test_receipt_delivered_raisesOutgoingMessageToDelivered() async throws {
        let outgoingID = UUID()
        await seedOutgoing(id: outgoingID, status: .sent)
        let receipt = ChatReceiptPayload(
            version: 1, groupID: groupIDBytes,
            senderBlsPubkeyHex: senderBlsHex, kind: .delivered, messageIDs: [outgoingID]
        )
        let dispatcher = makeDispatcher(
            plaintext: try JSONEncoder().encode(receipt),
            envelopeSigner: senderEd25519
        )
        await dispatcher.dispatch(
            messageID: "rcpt-1", ownerIdentityID: owner,
            payload: Data("envelope".utf8), receivedAt: Date()
        )
        let stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertEqual(stored.first { $0.id == outgoingID }?.status, .delivered)
    }

    func test_receipt_read_honoredOnlyWhenReadReceiptsEnabled() async throws {
        // Setting OFF → inbound read receipt ignored (stays delivered).
        let idOff = UUID()
        await seedOutgoing(id: idOff, status: .delivered)
        let readReceipt = ChatReceiptPayload(
            version: 1, groupID: groupIDBytes,
            senderBlsPubkeyHex: senderBlsHex, kind: .read, messageIDs: [idOff]
        )
        let off = makeDispatcher(
            plaintext: try JSONEncoder().encode(readReceipt),
            envelopeSigner: senderEd25519,
            readReceiptsEnabled: { false }
        )
        await off.dispatch(messageID: "r", ownerIdentityID: owner,
                           payload: Data("e".utf8), receivedAt: Date())
        var stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertEqual(stored.first { $0.id == idOff }?.status, .delivered,
                       "read receipt must be ignored while read receipts are disabled")

        // Setting ON → same receipt raises to read.
        let on = makeDispatcher(
            plaintext: try JSONEncoder().encode(readReceipt),
            envelopeSigner: senderEd25519,
            readReceiptsEnabled: { true }
        )
        await on.dispatch(messageID: "r2", ownerIdentityID: owner,
                          payload: Data("e".utf8), receivedAt: Date())
        stored = await messages.currentMessages(groupID: groupIDHex, owner: owner)
        XCTAssertEqual(stored.first { $0.id == idOff }?.status, .read)
    }

    private func seedOutgoing(id: UUID, status: MessageStatus) async {
        await messages.insert(ChatMessage(
            id: id, groupID: groupIDHex, ownerIdentityID: owner,
            senderBlsPubkeyHex: "ff".repeated(48), body: "mine",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: .outgoing, status: status,
            replyToMessageID: nil, groupType: .tyranny
        ))
    }
}

/// Records receipt sends so tests can assert the delivered ack.
private actor SpyChatReceiptSender: ChatReceiptSending {
    struct Sent: Sendable {
        let kind: ChatReceiptPayload.Kind
        let messageIDs: [UUID]
        let groupID: Data
        let recipientInboxKey: Data
    }
    private(set) var sends: [Sent] = []
    func send(
        kind: ChatReceiptPayload.Kind,
        messageIDs: [UUID],
        groupID: Data,
        to recipientInboxKey: Data
    ) async {
        sends.append(Sent(kind: kind, messageIDs: messageIDs, groupID: groupID, recipientInboxKey: recipientInboxKey))
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}

/// Stub `IdentitiesProviding` for the chat-message dispatcher tests.
/// The chat branch doesn't read identities (sender attribution comes
/// from the payload, verified against `memberProfiles`), so this can
/// always return empty. Duplicated from the announcement-test file's
/// private stub because Swift `private` is file-scoped.
private actor StubIdentities: IdentitiesProviding {
    private let summaries: [IdentitySummary]

    init(summaries: [IdentitySummary]) {
        self.summaries = summaries
    }

    func currentIdentities() -> [IdentitySummary] { summaries }
}
