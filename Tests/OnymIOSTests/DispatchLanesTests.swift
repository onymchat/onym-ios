import XCTest
@testable import OnymIOS

/// PR-5 of the reconnect design: invitation / group-state payloads ride
/// a serial slow lane so a backlog of chain-verifying handlers can never
/// starve live chat (F6). Chat messages and receipts stay inline.
final class DispatchLanesTests: XCTestCase {
    private let owner = IdentityID()

    // MARK: - SerialDispatchLane

    func test_lane_runsJobsInFIFOOrder() async {
        let lane = SerialDispatchLane()
        let box = OrderBox()
        for i in 0..<20 {
            await lane.enqueue { await box.append(i) }
        }
        await lane.drain()
        let order = await box.all()
        XCTAssertEqual(order, Array(0..<20), "slow-lane jobs must run strictly FIFO")
    }

    func test_lane_enqueueDoesNotBlockOnRunningJob() async {
        let lane = SerialDispatchLane()
        let gate = Gate()
        await lane.enqueue { await gate.wait() }  // job that blocks until opened

        // Enqueueing behind a blocked job must return immediately.
        let start = Date()
        await lane.enqueue {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5,
                          "enqueue must never wait for running jobs")
        await gate.open()
        await lane.drain()
    }

    func test_lane_drainWaitsForChainedJobs() async {
        let lane = SerialDispatchLane()
        let box = OrderBox()
        await lane.enqueue {
            await box.append(1)
            // A running job enqueues a successor (the chat retry shape).
            await lane.enqueue { await box.append(2) }
        }
        await lane.drain()
        let order = await box.all()
        XCTAssertEqual(order, [1, 2], "drain must also cover jobs enqueued by running jobs")
    }

    // MARK: - Starvation: slow payloads must not delay chat

    func test_chatMessage_isNotStarvedBySlowGroupStateWork() async throws {
        // A refresh request whose handler stalls (models a slow chain
        // read) is dispatched first; the chat message dispatched right
        // after must land in the repository without waiting for it.
        let group = TestGroupFactory.group(owner: owner)
        let groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        _ = await groups.insert(group.chatGroup)
        let messages = MessageRepository(store: SwiftDataMessageStore.inMemory())

        let refresh = TestGroupFactory.refreshRequest(group: group)
        let chat = TestGroupFactory.chatMessagePayload(group: group, body: "live message")
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .scripted([
                Data("refresh-envelope".utf8): try JSONEncoder().encode(refresh),
                Data("chat-envelope".utf8): try JSONEncoder().encode(chat),
            ]),
            senderEd25519PublicKey: group.senderEd25519
        )
        let stalledRefresher = StallingRefresher(stallSeconds: 2)
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentitiesForLanes(),
            groupRepository: groups,
            invitationsRepository: IncomingInvitationsRepository(store: SwiftDataInvitationStore.inMemory()),
            chainState: ThrowingChainStateForLanes(),
            messageRepository: messages,
            groupStateRefresher: stalledRefresher
        )

        // Slow payload first — it occupies the slow lane for ~2s.
        await dispatcher.dispatch(
            messageID: "m-refresh", ownerIdentityID: owner,
            payload: Data("refresh-envelope".utf8), receivedAt: Date()
        )
        // Chat message next — must not wait behind it.
        let start = Date()
        await dispatcher.dispatch(
            messageID: "m-chat", ownerIdentityID: owner,
            payload: Data("chat-envelope".utf8), receivedAt: Date()
        )
        let dispatchLatency = Date().timeIntervalSince(start)

        let persisted = await messages.currentMessages(
            groupID: group.chatGroup.id, owner: owner
        )
        XCTAssertEqual(persisted.map(\.body), ["live message"],
                       "the chat message must be persisted immediately")
        XCTAssertLessThan(dispatchLatency, 1.0,
                          "chat dispatch must not stall behind slow group-state work")
        await dispatcher.drainSlowLane()
    }

    // MARK: - Group-not-found retry through the slow lane

    func test_chatArrivingBeforeGroupMaterializes_isRetriedAfterSlowLane() async throws {
        // The lane-split race: a chat message reaches the fast lane while
        // the work that materializes its group is still queued in the
        // slow lane. The retry must run AFTER that work and persist.
        let group = TestGroupFactory.group(owner: owner)
        let groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        let messages = MessageRepository(store: SwiftDataMessageStore.inMemory())

        let refresh = TestGroupFactory.refreshRequest(group: group)
        let chat = TestGroupFactory.chatMessagePayload(group: group, body: "raced ahead")
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .scripted([
                Data("materialize-envelope".utf8): try JSONEncoder().encode(refresh),
                Data("chat-envelope".utf8): try JSONEncoder().encode(chat),
            ]),
            senderEd25519PublicKey: group.senderEd25519
        )
        // A "refresher" that materializes the group when it runs —
        // standing in for the invitation handler occupying the slow lane.
        let materializer = MaterializingRefresher(groups: groups, group: group.chatGroup)
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentitiesForLanes(),
            groupRepository: groups,
            invitationsRepository: IncomingInvitationsRepository(store: SwiftDataInvitationStore.inMemory()),
            chainState: ThrowingChainStateForLanes(),
            messageRepository: messages,
            groupStateRefresher: materializer
        )

        // Slow lane: the group-materializing work.
        await dispatcher.dispatch(
            messageID: "m-mat", ownerIdentityID: owner,
            payload: Data("materialize-envelope".utf8), receivedAt: Date()
        )
        // Fast lane: the chat message — group doesn't exist yet.
        await dispatcher.dispatch(
            messageID: "m-chat", ownerIdentityID: owner,
            payload: Data("chat-envelope".utf8), receivedAt: Date()
        )
        await dispatcher.drainSlowLane()

        let persisted = await messages.currentMessages(
            groupID: group.chatGroup.id, owner: owner
        )
        XCTAssertEqual(persisted.map(\.body), ["raced ahead"],
                       "the retry must land once the slow lane materializes the group")
    }

    func test_chatForGenuinelyUnknownGroup_isDroppedAfterOneRetry() async throws {
        let group = TestGroupFactory.group(owner: owner)
        let messages = MessageRepository(store: SwiftDataMessageStore.inMemory())
        let chat = TestGroupFactory.chatMessagePayload(group: group, body: "stale")
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: FakeInvitationEnvelopeDecrypter(
                mode: .fixed(try JSONEncoder().encode(chat)),
                senderEd25519PublicKey: group.senderEd25519
            ),
            identities: StubIdentitiesForLanes(),
            groupRepository: GroupRepository(store: SwiftDataGroupStore.inMemory()),
            invitationsRepository: IncomingInvitationsRepository(store: SwiftDataInvitationStore.inMemory()),
            chainState: ThrowingChainStateForLanes(),
            messageRepository: messages
        )

        await dispatcher.dispatchAndDrain(
            messageID: "m1", ownerIdentityID: owner,
            payload: Data("envelope".utf8), receivedAt: Date()
        )
        let persisted = await messages.currentMessages(
            groupID: group.chatGroup.id, owner: owner
        )
        XCTAssertTrue(persisted.isEmpty, "no group after the retry ⇒ drop, no infinite loop")
    }
}

// MARK: - Test doubles

/// Shared factory for a group + a matching signed chat payload, so the
/// insider-spoof guards pass.
private enum TestGroupFactory {
    struct Made {
        let chatGroup: ChatGroup
        let senderBlsHex: String
        let senderEd25519: Data
    }

    static func group(owner: IdentityID) -> Made {
        let senderBlsHex = String(repeating: "11", count: 48)
        let senderEd25519 = Data(repeating: 0xED, count: 32)
        let groupID = Data(repeating: 0x42, count: 32)
        let group = ChatGroup(
            id: groupID.map { String(format: "%02x", $0) }.joined(),
            ownerIdentityID: owner,
            name: "Lane Group",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            members: [],
            memberProfiles: [
                senderBlsHex: MemberProfile(
                    alias: "Alice",
                    inboxPublicKey: Data(repeating: 0x10, count: 32),
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
        return Made(chatGroup: group, senderBlsHex: senderBlsHex, senderEd25519: senderEd25519)
    }

    static func chatMessagePayload(group: Made, body: String) -> ChatMessagePayload {
        ChatMessagePayload(
            version: 1,
            messageID: UUID(),
            groupID: group.chatGroup.groupIDData,
            senderBlsPubkeyHex: group.senderBlsHex,
            sentAtMillis: 1_700_000_000_000,
            replyToMessageID: nil,
            variant: .tyranny(body: body)
        )
    }

    static func refreshRequest(group: Made) -> GroupStateRefreshRequest {
        try! GroupStateRefreshRequest(
            groupID: group.chatGroup.groupIDData,
            requesterInboxPublicKey: Data(repeating: 0x21, count: 32),
            requesterBlsPublicKey: Data(repeating: 0x31, count: 48)
        )
    }
}

private struct StubIdentitiesForLanes: IdentitiesProviding {
    func currentIdentities() async -> [IdentitySummary] { [] }
}

private struct ThrowingChainStateForLanes: ChainStateReading {
    func tyrannyCommitment(groupID: Data) async throws -> SEPCommitmentEntry {
        throw URLError(.unsupportedURL)
    }
}

/// Refresher that stalls — models a slow chain read occupying the lane.
private struct StallingRefresher: GroupStateRefreshing {
    let stallSeconds: Double
    func deferVerification(invitation: GroupInvitationPayload, ownerIdentityID: IdentityID) async {}
    func handleRefreshRequest(
        _ request: GroupStateRefreshRequest,
        ownerIdentityID: IdentityID,
        requesterEd25519: Data?
    ) async {
        try? await Task.sleep(for: .seconds(stallSeconds))
    }
}

/// Refresher that materializes a group when it runs — stands in for the
/// invitation handler in the slow lane.
private struct MaterializingRefresher: GroupStateRefreshing {
    let groups: GroupRepository
    let group: ChatGroup
    func deferVerification(invitation: GroupInvitationPayload, ownerIdentityID: IdentityID) async {}
    func handleRefreshRequest(
        _ request: GroupStateRefreshRequest,
        ownerIdentityID: IdentityID,
        requesterEd25519: Data?
    ) async {
        _ = await groups.insert(group)
    }
}

private actor OrderBox {
    private var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
    func all() -> [Int] { values }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
