import XCTest
@testable import OnymIOS

/// Behavioral tests for `IncomingMessageDispatcher` — the receive-side
/// fan-out target that decides whether an inbound inbox message is a
/// member-roster announcement (apply directly to memberProfiles) or a
/// regular invitation (store opaque for later display).
@MainActor
final class IncomingMessageDispatcherTests: XCTestCase {

    private var groups: GroupRepository!
    private var invitationsStore: DispatcherInvitationStore!
    private var invitations: IncomingInvitationsRepository!
    private var owner: IdentityID!

    override func setUp() async throws {
        try await super.setUp()
        groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        invitationsStore = DispatcherInvitationStore()
        invitations = IncomingInvitationsRepository(store: invitationsStore)
        owner = IdentityID()
        await groups.setCurrentIdentity(owner)
    }

    override func tearDown() async throws {
        groups = nil
        invitations = nil
        invitationsStore = nil
        owner = nil
        try await super.tearDown()
    }

    // MARK: - Announcement path

    func test_announcement_forKnownGroup_appendsToMemberProfiles() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        let creator = MemberProfile(
            alias: "Alice",
            inboxPublicKey: Data(repeating: 0x10, count: 32)
        )
        let creatorBlsHex = "aa".repeated(48)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [creatorBlsHex: creator]
        )

        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "bb".repeated(48),
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations
        )

        await dispatcher.dispatch(
            messageID: "msg-1",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        let updated = try XCTUnwrap(after.first { $0.groupIDData == groupID })
        XCTAssertEqual(updated.memberProfiles.count, 2,
                       "creator + new joiner")
        XCTAssertEqual(updated.memberProfiles["bb".repeated(48)]?.alias, "Bob")
        let storedCount = await invitationsStore.count
        XCTAssertEqual(storedCount, 0,
                       "announcements must NOT land in the invitations queue")
    }

    func test_announcement_forUnknownGroup_isNoOp() async throws {
        // Group repository is empty.
        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: Data(repeating: 0xCD, count: 32),
            joinerBlsHex: "ee".repeated(48),
            joinerInboxByte: 0x77,
            joinerAlias: "stranger",
            adminAlias: "unknown admin"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations
        )

        await dispatcher.dispatch(
            messageID: "msg-2",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty)
        let storedCount = await invitationsStore.count
        XCTAssertEqual(storedCount, 0,
                       "unknown-group announcement is dropped, not stored as invitation")
    }

    func test_announcement_forKnownMember_isIdempotentNoOp() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        let bobBlsHex = "bb".repeated(48)
        let bob = MemberProfile(
            alias: "Bob (original)",
            inboxPublicKey: Data(repeating: 0x33, count: 32)
        )
        await seedGroup(
            groupID: groupID,
            memberProfiles: [bobBlsHex: bob]
        )

        // Re-announce Bob (e.g. relay redelivery) with a fresh alias —
        // dispatcher must dedupe by BLS pubkey hex and NOT overwrite.
        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: bobBlsHex,
            joinerInboxByte: 0x33,
            joinerAlias: "Bob (renamed)",
            adminAlias: "admin"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations
        )

        await dispatcher.dispatch(
            messageID: "msg-3",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        let updated = try XCTUnwrap(after.first { $0.groupIDData == groupID })
        XCTAssertEqual(updated.memberProfiles[bobBlsHex]?.alias, "Bob (original)",
                       "redelivery must NOT overwrite an existing profile")
    }

    // MARK: - Invitation materialization path

    func test_invitation_materializesLocalGroup_withSelfEntry() async throws {
        // Joiner-side: receive a fresh invitation for a group that
        // doesn't exist locally. Dispatcher materializes a ChatGroup
        // and adds the receiver's own profile to memberProfiles.
        let creatorBlsHex = "11".repeated(48)
        let creatorProfile = MemberProfile(
            alias: "Alice",
            inboxPublicKey: Data(repeating: 0xAA, count: 32)
        )
        let payload = makeInvitationPayload(
            groupID: Data(repeating: 0x42, count: 32),
            name: "Family",
            memberProfiles: [creatorBlsHex: creatorProfile]
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))

        // Self has a different BLS pubkey from the creator — receiver
        // is the joiner, not the admin.
        let selfBlsHex = "22".repeated(48)
        let selfSummary = IdentitySummary(
            id: owner,
            name: "Bob",
            blsPublicKey: Data(repeating: 0x22, count: 48),
            inboxPublicKey: Data(repeating: 0xBB, count: 32)
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: [selfSummary]),
            groupRepository: groups,
            invitationsRepository: invitations
        )

        await dispatcher.dispatch(
            messageID: "msg-mat",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        let materialized = try XCTUnwrap(after.first)
        XCTAssertEqual(materialized.name, "Family")
        XCTAssertEqual(materialized.ownerIdentityID, owner)
        XCTAssertEqual(materialized.memberProfiles.count, 2,
                       "creator (from wire) + self (from identity provider)")
        XCTAssertEqual(materialized.memberProfiles[creatorBlsHex]?.alias, "Alice")
        XCTAssertEqual(materialized.memberProfiles[selfBlsHex]?.alias, "Bob")
        XCTAssertTrue(materialized.isPublishedOnChain,
                      "sender already anchored before sending the invite")
        let storedCount = await invitationsStore.count
        XCTAssertEqual(storedCount, 0,
                       "materialized invitations must NOT also queue as pending")
    }

    func test_invitation_withoutMemberProfiles_materializesWithSelfOnly() async throws {
        // Legacy / pre-PR-8a sender — no member_profiles on the wire.
        // Receiver still materializes; directory carries just self.
        let payload = makeInvitationPayload(
            groupID: Data(repeating: 0x99, count: 32),
            name: "Legacy",
            memberProfiles: nil
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))

        let selfSummary = IdentitySummary(
            id: owner,
            name: "Carol",
            blsPublicKey: Data(repeating: 0x33, count: 48),
            inboxPublicKey: Data(repeating: 0xCC, count: 32)
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: [selfSummary]),
            groupRepository: groups,
            invitationsRepository: invitations
        )

        await dispatcher.dispatch(
            messageID: "msg-legacy",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        XCTAssertEqual(after.first?.memberProfiles.count, 1,
                       "wire didn't carry profiles, but self entry still gets added")
        XCTAssertEqual(after.first?.memberProfiles["33".repeated(48)]?.alias, "Carol")
    }

    func test_invitation_unresolvableSelf_materializesWithoutSelfEntry() async throws {
        // Identity provider returns an empty list (race during
        // identity removal, fresh wipe, etc.). Materializer must not
        // crash and must still create the group with the wire-shipped
        // directory only.
        let creatorBlsHex = "44".repeated(48)
        let payload = makeInvitationPayload(
            groupID: Data(repeating: 0xEE, count: 32),
            name: "Race",
            memberProfiles: [creatorBlsHex: MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0x44, count: 32)
            )]
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations
        )

        await dispatcher.dispatch(
            messageID: "msg-race",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        XCTAssertEqual(after.first?.memberProfiles.count, 1,
                       "wire-shipped directory survives even without self resolution")
    }

    // MARK: - Fall-through path

    func test_undecodableJSON_fallsThroughToInvitations() async throws {
        // Decryption succeeds but plaintext isn't a MemberAnnouncementPayload.
        let plaintext = Data("not an announcement".utf8)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations
        )

        await dispatcher.dispatch(
            messageID: "msg-4",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let storedCount = await invitationsStore.count
        XCTAssertEqual(storedCount, 1,
                       "non-announcement plaintext falls through to invitations queue")
    }

    func test_decryptFailure_fallsThroughToInvitations() async throws {
        // Decryption fails entirely (corrupted envelope, wrong recipient, etc.).
        // Today's behavior is to store opaque ciphertext for later
        // hand-off to the invitations pipeline; the dispatcher must
        // preserve that.
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .failing(.signatureVerificationFailed)
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations
        )

        await dispatcher.dispatch(
            messageID: "msg-5",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let storedCount = await invitationsStore.count
        XCTAssertEqual(storedCount, 1,
                       "decrypt failure falls through (ciphertext kept for later pipeline)")
    }

    // MARK: - Helpers

    private func seedGroup(
        groupID: Data,
        memberProfiles: [String: MemberProfile]
    ) async {
        let group = ChatGroup(
            id: groupID.map { String(format: "%02x", $0) }.joined(),
            ownerIdentityID: owner,
            name: "Family",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            members: [],
            memberProfiles: memberProfiles,
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: nil,
            isPublishedOnChain: true
        )
        _ = await groups.insert(group)
    }

    private static func makeAnnouncement(
        groupID: Data,
        joinerBlsHex: String,
        joinerInboxByte: UInt8,
        joinerAlias: String,
        adminAlias: String
    ) throws -> MemberAnnouncementPayload {
        let blsPub = Data(joinerBlsHex.hexBytes)
        let member = try MemberAnnouncementPayload.AnnouncedMember(
            blsPub: blsPub,
            inboxPub: Data(repeating: joinerInboxByte, count: 32),
            alias: joinerAlias
        )
        return try MemberAnnouncementPayload(
            version: 1,
            groupId: groupID,
            newMember: member,
            adminAlias: adminAlias
        )
    }

    private static func encode(announcement: MemberAnnouncementPayload) throws -> Data {
        try JSONEncoder().encode(announcement)
    }

    private func makeInvitationPayload(
        groupID: Data,
        name: String,
        memberProfiles: [String: MemberProfile]?
    ) -> GroupInvitationPayload {
        GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: name,
            members: [],
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: Data(repeating: 0x77, count: 32),
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.tyranny.rawValue,
            adminPubkeyHex: nil,
            peerBlsSecret: nil,
            memberProfiles: memberProfiles
        )
    }
}

// MARK: - Stub identity provider

private actor StubIdentities: IdentitiesProviding {
    private let summaries: [IdentitySummary]

    init(summaries: [IdentitySummary]) {
        self.summaries = summaries
    }

    func currentIdentities() -> [IdentitySummary] { summaries }
}

// MARK: - String / hex helpers (test scope)

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }

    var hexBytes: [UInt8] {
        var bytes: [UInt8] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2, limitedBy: endIndex) ?? endIndex
            if let byte = UInt8(self[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }
}

// MARK: - Test double

private actor DispatcherInvitationStore: InvitationStore {
    private var rows: [String: IncomingInvitationRecord] = [:]

    var count: Int { rows.count }

    func list() -> [IncomingInvitationRecord] {
        rows.values.sorted { $0.receivedAt > $1.receivedAt }
    }

    @discardableResult
    func save(_ record: IncomingInvitationRecord) -> Bool {
        guard rows[record.id] == nil else { return false }
        rows[record.id] = record
        return true
    }

    func updateStatus(id: String, status: IncomingInvitationStatus) {
        guard let existing = rows[id] else { return }
        rows[id] = IncomingInvitationRecord(
            id: existing.id,
            ownerIdentityID: existing.ownerIdentityID,
            payload: existing.payload,
            receivedAt: existing.receivedAt,
            status: status
        )
    }

    func delete(id: String) {
        rows.removeValue(forKey: id)
    }

    func deleteOwner(_ ownerIDString: String) {
        rows = rows.filter { $0.value.ownerIdentityID.rawValue.uuidString != ownerIDString }
    }
}
