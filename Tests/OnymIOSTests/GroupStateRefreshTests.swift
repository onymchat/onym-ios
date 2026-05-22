import Foundation
import XCTest
@testable import OnymIOS

final class GroupStateRefreshRequestCodecTests: XCTestCase {
    func test_roundTrip() throws {
        let req = try GroupStateRefreshRequest(
            groupID: Data(repeating: 0x42, count: 32),
            requesterInboxPublicKey: Data(repeating: 0x11, count: 32),
            requesterBlsPublicKey: Data(repeating: 0x22, count: 48)
        )
        let decoded = try JSONDecoder().decode(
            GroupStateRefreshRequest.self,
            from: JSONEncoder().encode(req)
        )
        XCTAssertEqual(decoded, req)
    }

    func test_wrongSizes_throw() {
        XCTAssertThrowsError(try GroupStateRefreshRequest(
            groupID: Data(repeating: 0x42, count: 31),
            requesterInboxPublicKey: Data(repeating: 0x11, count: 32),
            requesterBlsPublicKey: Data(repeating: 0x22, count: 48)
        ))
        XCTAssertThrowsError(try GroupStateRefreshRequest(
            groupID: Data(repeating: 0x42, count: 32),
            requesterInboxPublicKey: Data(repeating: 0x11, count: 32),
            requesterBlsPublicKey: Data(repeating: 0x22, count: 32)  // BLS must be 48
        ))
    }

    /// An invite offer must not decode as a refresh request (disjoint
    /// required keys keep the dispatcher's trial-decode unambiguous).
    func test_offer_doesNotDecodeAsRefresh() throws {
        let offer = try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x11, count: 32),
            groupID: Data(repeating: 0x42, count: 32),
            groupName: "G",
            inviterAlias: "A"
        )
        let bytes = try JSONEncoder().encode(offer)
        XCTAssertThrowsError(try JSONDecoder().decode(GroupStateRefreshRequest.self, from: bytes))
    }
}

final class GroupStateVerifierTests: XCTestCase {
    private var keychain: IdentityKeychainStore!
    private var identity: IdentityRepository!
    private var groups: GroupRepository!
    private var transport: VerifierRecordingInboxTransport!
    private var store: PendingVerificationStore!
    private var owner: IdentityID!

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(testNamespace: "verifier-\(UUID().uuidString)")
        identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        transport = VerifierRecordingInboxTransport()
        store = PendingVerificationStore()
        owner = IdentityID()
        await groups.setCurrentIdentity(owner)
        await store.setCurrentIdentity(owner)
    }

    override func tearDown() async throws {
        try? keychain.wipeAll()
        keychain = nil; identity = nil; groups = nil; transport = nil; store = nil; owner = nil
        try await super.tearDown()
    }

    private func makeVerifier() -> GroupStateVerifier {
        GroupStateVerifier(
            identity: identity,
            inboxTransport: transport,
            groupRepository: groups,
            store: store
        )
    }

    /// A snapshot whose admin we can't reach (no admin entry in the
    /// shipped roster) is recorded as `.unreachable` and surfaced to the
    /// user — not silently dropped, never materialized.
    func test_deferVerification_noAdminInbox_marksUnreachable() async throws {
        let verifier = makeVerifier()
        let groupID = Data(repeating: 0x42, count: 32)
        let invitation = GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "Family",
            members: [],
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: Data(repeating: 0x77, count: 32),
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.tyranny.rawValue,
            adminPubkeyHex: String(repeating: "aa", count: 48),
            memberProfiles: nil  // admin not reachable
        )

        await verifier.deferVerification(invitation: invitation, ownerIdentityID: owner)

        let snapshot = await firstSnapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.status, .unreachable)
        let groupsAfter = await groups.currentGroups()
        XCTAssertTrue(groupsAfter.isEmpty, "deferral must not materialize a group")
        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 0, "no admin inbox → nothing to send")
    }

    /// The admin must not answer a refresh request from a non-member —
    /// the reply carries the salt.
    func test_handleRefreshRequest_nonMember_doesNotReply() async throws {
        let verifier = makeVerifier()
        let groupID = Data(repeating: 0x42, count: 32)
        let groupIDHex = String(repeating: "42", count: 32)
        let memberBlsHex = String(repeating: "bb", count: 48)
        let group = ChatGroup(
            id: groupIDHex,
            ownerIdentityID: owner,
            name: "Family",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(),
            members: [],
            memberProfiles: [memberBlsHex: MemberProfile(
                alias: "Member",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: Data(repeating: 0xEE, count: 32)
            )],
            epoch: 1,
            salt: Data(repeating: 0x66, count: 32),
            commitment: Data(repeating: 0x77, count: 32),
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: memberBlsHex,
            adminEd25519PubkeyHex: String(repeating: "ee", count: 32),
            isPublishedOnChain: true
        )
        _ = await groups.insert(group)

        // Requester whose BLS isn't in the roster.
        let request = try GroupStateRefreshRequest(
            groupID: groupID,
            requesterInboxPublicKey: Data(repeating: 0x01, count: 32),
            requesterBlsPublicKey: Data(repeating: 0x02, count: 48)
        )
        await verifier.handleRefreshRequest(
            request,
            ownerIdentityID: owner,
            requesterEd25519: Data(repeating: 0xAB, count: 32)
        )

        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 0, "non-member must not receive the current snapshot (salt)")
    }

    private func firstSnapshot() async -> [PendingGroupVerification] {
        for await snapshot in store.snapshots { return snapshot }
        return []
    }
}

// MARK: - Local recording transport

private actor VerifierRecordingInboxTransport: InboxTransport {
    private(set) var sends: Int = 0
    func connect(to endpoints: [TransportEndpoint]) async {}
    func disconnect() async {}
    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        sends += 1
        return PublishReceipt(messageID: "spy-\(sends)", acceptedBy: 1)
    }
    nonisolated func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        AsyncStream { _ in }
    }
    func unsubscribe(inbox: TransportInboxID) async {}
    func sendCount() -> Int { sends }
}
