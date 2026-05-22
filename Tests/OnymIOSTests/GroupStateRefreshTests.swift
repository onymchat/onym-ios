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

    /// The dispatcher trial-decodes the offer (fast-path 0) and the
    /// refresh request (fast-path 0.5) BEFORE the announcement /
    /// invitation / join-request / chat-message paths. Guard against
    /// future schema drift: none of those must decode as either control
    /// payload.
    func test_otherPayloads_doNotDecodeAsOfferOrRefresh() throws {
        let announce = try MemberAnnouncementPayload(
            version: 1,
            groupId: Data(repeating: 0x42, count: 32),
            newMember: MemberAnnouncementPayload.AnnouncedMember(
                blsPub: Data(repeating: 0x01, count: 48),
                inboxPub: Data(repeating: 0x02, count: 32),
                alias: "X",
                sendingPub: Data(repeating: 0x03, count: 32)
            ),
            adminAlias: "A"
        )
        let invite = GroupInvitationPayload(
            version: 1,
            groupID: Data(repeating: 0x42, count: 32),
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "G",
            members: [],
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: nil,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.tyranny.rawValue,
            adminPubkeyHex: nil,
            memberProfiles: nil
        )
        let join = try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0x01, count: 32),
            joinerBlsPublicKey: Data(repeating: 0x02, count: 48),
            joinerLeafHash: Data(repeating: 0x03, count: 32),
            joinerSendingPublicKey: Data(repeating: 0x04, count: 32),
            joinerDisplayLabel: "B",
            groupId: Data(repeating: 0x05, count: 32)
        )
        let samples = try [
            JSONEncoder().encode(announce),
            JSONEncoder().encode(invite),
            JSONEncoder().encode(join),
        ]
        for bytes in samples {
            XCTAssertThrowsError(try JSONDecoder().decode(GroupInviteOfferPayload.self, from: bytes))
            XCTAssertThrowsError(try JSONDecoder().decode(GroupStateRefreshRequest.self, from: bytes))
        }
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
        // Bootstrap so `currentIdentity()` is non-nil — the admin-side
        // "am I the admin?" guard needs a real BLS to compare against.
        _ = try await identity.bootstrap()
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
    /// the reply carries the salt. (We ARE the admin here, so the
    /// admin-guard passes and the membership gate is what rejects.)
    func test_handleRefreshRequest_nonMember_doesNotReply() async throws {
        let verifier = makeVerifier()
        let myBlsHex = await myBlsHex()
        let group = seedTyrannyGroup(
            adminPubkeyHex: myBlsHex,
            memberProfiles: [myBlsHex: MemberProfile(
                alias: "Admin",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: Data(repeating: 0xEE, count: 32)
            )]
        )
        _ = await groups.insert(group)

        // Requester whose BLS isn't in the roster.
        let request = try GroupStateRefreshRequest(
            groupID: Data(repeating: 0x42, count: 32),
            requesterInboxPublicKey: Data(repeating: 0x01, count: 32),
            requesterBlsPublicKey: Data(repeating: 0x02, count: 48)
        )
        await verifier.handleRefreshRequest(
            request, ownerIdentityID: owner, requesterEd25519: Data(repeating: 0xAB, count: 32)
        )

        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 0, "non-member must not receive the current snapshot (salt)")
    }

    /// If this device isn't the group's admin, refuse even a real member
    /// — only the admin holds and should disclose the current salt.
    func test_handleRefreshRequest_notAdmin_doesNotReply() async throws {
        let verifier = makeVerifier()
        let requesterBls = Data(repeating: 0x02, count: 48)
        let requesterBlsHex = requesterBls.map { String(format: "%02x", $0) }.joined()
        // adminPubkeyHex is some OTHER key — not this device's BLS.
        let group = seedTyrannyGroup(
            adminPubkeyHex: String(repeating: "bb", count: 48),
            memberProfiles: [requesterBlsHex: MemberProfile(
                alias: "Member",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: Data(repeating: 0xEE, count: 32)
            )]
        )
        _ = await groups.insert(group)

        let request = try GroupStateRefreshRequest(
            groupID: Data(repeating: 0x42, count: 32),
            requesterInboxPublicKey: Data(repeating: 0x10, count: 32),
            requesterBlsPublicKey: requesterBls
        )
        await verifier.handleRefreshRequest(
            request, ownerIdentityID: owner, requesterEd25519: Data(repeating: 0xEE, count: 32)
        )

        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 0, "a non-admin device must not answer refresh requests")
    }

    /// Full loop: a pending verification is cleared once the fresh
    /// snapshot materializes the group.
    func test_resolve_clearsPendingWhenGroupMaterializes() async throws {
        let verifier = makeVerifier()
        await verifier.start()
        let groupID = Data(repeating: 0x42, count: 32)
        let groupIDHex = hex(groupID)
        // No-admin snapshot → recorded as pending (unreachable).
        await verifier.deferVerification(
            invitation: tyrannyInvitation(adminPubkeyHex: String(repeating: "aa", count: 48),
                                          memberProfiles: nil),
            ownerIdentityID: owner
        )
        let present = await store.contains(groupIDHex: groupIDHex)
        XCTAssertTrue(present)

        // Materialize the group → watcher resolves the pending entry.
        _ = await groups.insert(seedTyrannyGroup(
            adminPubkeyHex: String(repeating: "aa", count: 48),
            memberProfiles: [:]
        ))
        try await waitUntil {
            let stillPending = await self.store.contains(groupIDHex: groupIDHex)
            return !stillPending
        }
    }

    /// The 30/60s timer transitions a sent-but-unanswered request from
    /// `.verifying` to `.unreachable` (tiny timeout for the test).
    func test_timeout_transitionsVerifyingToUnreachable() async throws {
        let verifier = GroupStateVerifier(
            identity: identity,
            inboxTransport: transport,
            groupRepository: groups,
            store: store,
            refreshTimeoutSeconds: 0
        )
        let adminBlsHex = String(repeating: "aa", count: 48)
        await verifier.deferVerification(
            invitation: tyrannyInvitation(
                adminPubkeyHex: adminBlsHex,
                memberProfiles: [adminBlsHex: MemberProfile(
                    alias: "Admin",
                    inboxPublicKey: Data(repeating: 0x10, count: 32),
                    sendingPubkey: Data(repeating: 0xEE, count: 32)
                )]
            ),
            ownerIdentityID: owner
        )
        // A refresh was actually sent (reachable admin).
        let sent = await transport.sendCount()
        XCTAssertGreaterThanOrEqual(sent, 1)
        // …and the timer flips it to unreachable.
        let groupIDHex = hex(Data(repeating: 0x42, count: 32))
        try await waitUntil {
            let status = await self.store.status(groupIDHex: groupIDHex)
            return status == .unreachable
        }
    }

    // MARK: - Helpers

    private func firstSnapshot() async -> [PendingGroupVerification] {
        for await snapshot in store.snapshots { return snapshot }
        return []
    }

    private func myBlsHex() async -> String {
        let me = await identity.currentIdentity()
        return (me?.blsPublicKey ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func tyrannyInvitation(
        adminPubkeyHex: String?,
        memberProfiles: [String: MemberProfile]?
    ) -> GroupInvitationPayload {
        GroupInvitationPayload(
            version: 1,
            groupID: Data(repeating: 0x42, count: 32),
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "Family",
            members: [],
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: Data(repeating: 0x77, count: 32),
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.tyranny.rawValue,
            adminPubkeyHex: adminPubkeyHex,
            memberProfiles: memberProfiles
        )
    }

    private func seedTyrannyGroup(
        adminPubkeyHex: String,
        memberProfiles: [String: MemberProfile]
    ) -> ChatGroup {
        ChatGroup(
            id: String(repeating: "42", count: 32),
            ownerIdentityID: owner,
            name: "Family",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(),
            members: [],
            memberProfiles: memberProfiles,
            epoch: 1,
            salt: Data(repeating: 0x66, count: 32),
            commitment: Data(repeating: 0x77, count: 32),
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: adminPubkeyHex,
            adminEd25519PubkeyHex: String(repeating: "ee", count: 32),
            isPublishedOnChain: true
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
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
