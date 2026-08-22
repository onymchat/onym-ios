import XCTest
import CryptoKit
@testable import OnymIOS
import OnymChain
import OnymIdentity
import OnymGroup
import OnymPersistence
import OnymChatsCore
import OnymInbox

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
    private var chainState: DispatcherStubChainState!

    override func setUp() async throws {
        try await super.setUp()
        groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        invitationsStore = DispatcherInvitationStore()
        invitations = IncomingInvitationsRepository(store: invitationsStore)
        owner = IdentityID()
        await groups.setCurrentIdentity(owner)
        chainState = DispatcherStubChainState()
    }

    override func tearDown() async throws {
        groups = nil
        invitations = nil
        invitationsStore = nil
        owner = nil
        chainState = nil
        try await super.tearDown()
    }

    // MARK: - Announcement path

    func test_announcement_forKnownGroup_appendsToMemberProfiles() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        let creator = MemberProfile(
            alias: "Alice",
            inboxPublicKey: Data(repeating: 0x10, count: 32),
            sendingPubkey: Data(repeating: 0xEE, count: 32)
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
        // H-2: admin-less group — the announcement must be signed by a
        // current member (the creator, sendingPubkey 0xEE).
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xEE, count: 32)
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
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
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
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
            inboxPublicKey: Data(repeating: 0x33, count: 32),
            sendingPubkey: Data(repeating: 0xEE, count: 32)
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
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
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

    // MARK: - PR 9: admin Ed25519 trust check

    func test_announcement_acceptedWhenSenderMatchesStoredAdminEd25519() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        let adminEd25519 = Data(repeating: 0xED, count: 32)
        let adminEd25519Hex = "ed".repeated(32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [:],
            adminEd25519PubkeyHex: adminEd25519Hex
        )

        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "bb".repeated(48),
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: adminEd25519
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-trust-ok",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        let updated = try XCTUnwrap(after.first { $0.groupIDData == groupID })
        XCTAssertEqual(updated.memberProfiles["bb".repeated(48)]?.alias, "Bob",
                       "matched-admin announcement is accepted")
    }

    func test_announcement_rejectedWhenSenderDoesNotMatchStoredAdmin() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        let adminEd25519Hex = "ed".repeated(32)
        let imposterEd25519 = Data(repeating: 0xBA, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [:],
            adminEd25519PubkeyHex: adminEd25519Hex
        )

        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "ff".repeated(48),
            joinerInboxByte: 0x99,
            joinerAlias: "Mallory",
            adminAlias: "imposter"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: imposterEd25519
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-trust-bad",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        let updated = try XCTUnwrap(after.first { $0.groupIDData == groupID })
        XCTAssertNil(updated.memberProfiles["ff".repeated(48)],
                     "imposter announcement must NOT mutate memberProfiles")
    }

    func test_announcement_rejectedWhenAdminKnownButEnvelopeUnsigned() async throws {
        // Group has a stored admin but the envelope didn't carry a
        // sender pubkey (no signature block). PR 9 rule: when we know
        // who the admin should be, an unsigned announcement is
        // dropped — best-effort acceptance only applies to legacy
        // groups with no stored admin Ed25519.
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [:],
            adminEd25519PubkeyHex: "ed".repeated(32)
        )
        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "bb".repeated(48),
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: nil
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-unsigned",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertNil(after.first?.memberProfiles["bb".repeated(48)],
                     "unsigned announcement is dropped when the group has a stored admin")
    }

    func test_announcement_adminLessGroup_acceptedWhenSignerIsCurrentMember() async throws {
        // H-2: an admin-less group (anarchy / oneOnOne / pre-PR-9) no
        // longer skips the sender check. The announcement is accepted
        // only when the verified signer is a CURRENT member — here the
        // existing member Alice (sendingPubkey == the envelope signer).
        let groupID = Data(repeating: 0xAB, count: 32)
        let memberEd25519 = Data(repeating: 0xAA, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["aa".repeated(48): MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: memberEd25519
            )],
            adminEd25519PubkeyHex: nil
        )
        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "bb".repeated(48),
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: memberEd25519
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-adminless-member",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertEqual(after.first?.memberProfiles["bb".repeated(48)]?.alias, "Bob",
                       "admin-less group accepts an announcement signed by a current member")
    }

    func test_announcement_adminLessGroup_rejectedWhenSignerNotMember() async throws {
        // H-2: the pre-fix bug — an admin-less group applied any
        // announcement unconditionally. Now a signer who is NOT a
        // current member is rejected.
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["aa".repeated(48): MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: Data(repeating: 0xAA, count: 32)
            )],
            adminEd25519PubkeyHex: nil
        )
        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "bb".repeated(48),
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xBE, count: 32)  // not a member
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-adminless-nonmember",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertNil(after.first?.memberProfiles["bb".repeated(48)],
                     "admin-less group must reject an announcement from a non-member")
    }

    func test_announcement_adminLessGroup_rejectedWhenUnsigned() async throws {
        // H-2: a missing signer is never treated as authorized, even
        // for admin-less groups.
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["aa".repeated(48): MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: Data(repeating: 0xAA, count: 32)
            )],
            adminEd25519PubkeyHex: nil
        )
        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "bb".repeated(48),
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: nil
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-adminless-unsigned",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertNil(after.first?.memberProfiles["bb".repeated(48)],
                     "admin-less group must reject an unsigned announcement")
    }

    // MARK: - H-2: admin-less name / avatar

    func test_name_adminLessGroup_rejectedWhenSignerNotMember() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["aa".repeated(48): MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: Data(repeating: 0xAA, count: 32)
            )],
            adminEd25519PubkeyHex: nil
        )
        let plaintext = try Self.encode(name: Self.makeName(groupID: groupID, name: "Hacked"))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xBE, count: 32)  // not a member
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "name-adminless-nonmember",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertEqual(after.first { $0.groupIDData == groupID }?.name, "Family",
                       "admin-less group must reject a rename from a non-member")
    }

    func test_avatar_adminLessGroup_rejectedWhenSignerNotMember() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["aa".repeated(48): MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: Data(repeating: 0xAA, count: 32)
            )],
            adminEd25519PubkeyHex: nil
        )
        let plaintext = try Self.encode(avatar: Self.makeAvatar(
            groupID: groupID,
            jpeg: Data(repeating: 0x01, count: 64)
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xBE, count: 32)  // not a member
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "avatar-adminless-nonmember",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertNil(after.first { $0.groupIDData == groupID }?.avatarJPEG,
                     "admin-less group must reject an avatar update from a non-member")
    }

    func test_name_adminLessGroup_acceptedWhenSignerIsMember() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        let memberEd25519 = Data(repeating: 0xAA, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["aa".repeated(48): MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: memberEd25519
            )],
            adminEd25519PubkeyHex: nil
        )
        let plaintext = try Self.encode(name: Self.makeName(groupID: groupID, name: "Renamed"))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: memberEd25519
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "name-adminless-member",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertEqual(after.first { $0.groupIDData == groupID }?.name, "Renamed",
                       "admin-less group accepts a rename signed by a current member")
    }

    // MARK: - Avatar path (GroupAvatarPayload)

    func test_avatar_appliedWhenSenderMatchesStoredAdmin() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        let adminEd25519 = Data(repeating: 0xED, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [:],
            adminEd25519PubkeyHex: "ed".repeated(32)
        )
        let jpeg = Data(repeating: 0x7A, count: 800)
        let plaintext = try Self.encode(avatar: Self.makeAvatar(groupID: groupID, jpeg: jpeg))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: adminEd25519
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "avatar-ok",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertEqual(after.first { $0.groupIDData == groupID }?.avatarJPEG, jpeg,
                       "admin-signed avatar update is applied")
    }

    // MARK: - Rename path (GroupNamePayload)

    func test_name_appliedWhenSenderMatchesStoredAdmin() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        let adminEd25519 = Data(repeating: 0xED, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [:],
            adminEd25519PubkeyHex: "ed".repeated(32)
        )
        let plaintext = try Self.encode(name: Self.makeName(groupID: groupID, name: "Renamed"))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: adminEd25519
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "name-ok",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertEqual(after.first { $0.groupIDData == groupID }?.name, "Renamed",
                       "admin-signed rename is applied")
    }

    func test_name_rejectedWhenSenderDoesNotMatchStoredAdmin() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [:],
            adminEd25519PubkeyHex: "ed".repeated(32)
        )
        let plaintext = try Self.encode(name: Self.makeName(groupID: groupID, name: "Hacked"))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xBA, count: 32)  // imposter
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "name-imposter",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertEqual(after.first { $0.groupIDData == groupID }?.name, "Family",
                       "imposter rename must not mutate the group name")
    }

    func test_avatar_rejectedWhenSenderDoesNotMatchStoredAdmin() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [:],
            adminEd25519PubkeyHex: "ed".repeated(32)
        )
        let plaintext = try Self.encode(avatar: Self.makeAvatar(
            groupID: groupID,
            jpeg: Data(repeating: 0x01, count: 64)
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xBA, count: 32)  // imposter
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "avatar-imposter",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertNil(after.first { $0.groupIDData == groupID }?.avatarJPEG,
                     "imposter avatar update must not mutate the group photo")
    }

    func test_avatar_nilPayloadClearsExistingPhoto() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        let adminEd25519 = Data(repeating: 0xED, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [:],
            adminEd25519PubkeyHex: "ed".repeated(32),
            avatarJPEG: Data(repeating: 0x09, count: 128)
        )
        let plaintext = try Self.encode(avatar: Self.makeAvatar(groupID: groupID, jpeg: nil))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: adminEd25519
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "avatar-clear",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertNil(after.first { $0.groupIDData == groupID }?.avatarJPEG,
                     "admin-signed nil avatar clears the photo")
    }

    func test_invitation_capturesSenderEd25519AsAdmin() async throws {
        // PR 9: the materializer stamps the inviting envelope's
        // senderEd25519PublicKey as the group's adminEd25519PubkeyHex
        // for Tyranny groups, so subsequent announcements can be
        // verified against it.
        //
        // PR 13b (post-fix): Tyranny invitations require the wire
        // `commitment` to match Poseidon(Poseidon(merkle_root, epoch),
        // salt) AND the on-chain commitment. Compute the real
        // commitment from the (empty) test member list + the salt
        // that makeInvitationPayload uses, seed the chain stub.
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)  // matches makeInvitationPayload
        let realCommitment = try Self.makeRealTyrannyCommitment(
            members: [],
            epoch: 0,
            salt: salt,
            tier: .small
        )
        chainState.setNext(commitment: realCommitment, epoch: 0)
        let payload = makeInvitationPayload(
            groupID: groupID,
            name: "Family",
            memberProfiles: nil,
            groupType: .tyranny,
            commitment: realCommitment
        )
        let plaintext = try JSONEncoder().encode(payload)
        let admin = Data(repeating: 0xED, count: 32)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: admin
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-cap",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertEqual(after.first?.adminEd25519PubkeyHex, "ed".repeated(32),
                       "materializer stamps sender Ed25519 hex on the new group")
    }

    // MARK: - PR 13b on-chain commitment verification

    func test_invitation_tyranny_rejectsWhenCommitmentMissing() async throws {
        // Pre-PR-13a sender shipped a Tyranny invitation without
        // commitment. PR 13b receivers MUST reject — without the
        // commitment we can't verify against the chain.
        let groupID = Data(repeating: 0x42, count: 32)
        let payload = makeInvitationPayload(
            groupID: groupID,
            name: "Family",
            memberProfiles: nil,
            groupType: .tyranny,
            commitment: nil
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-no-commitment",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty,
                      "Tyranny invitation without commitment must be rejected")
    }

    func test_invitation_tyranny_rejectsWhenOnchainCommitmentMismatch() async throws {
        // The dispatcher recomputes Poseidon(Poseidon(root, epoch),
        // salt) from the wire and verifies it matches BOTH the
        // payload's commitment AND the on-chain state. If on-chain
        // disagrees (the sender forged a fake commitment that
        // happens to be self-consistent), reject the invitation.
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)
        let internallyConsistent = try Self.makeRealTyrannyCommitment(
            members: [],
            epoch: 0,
            salt: salt,
            tier: .small
        )
        // Payload's commitment is internally consistent; chain
        // says something different.
        chainState.setNext(commitment: Data(repeating: 0xFF, count: 32), epoch: 0)
        let payload = makeInvitationPayload(
            groupID: groupID,
            name: "Family",
            memberProfiles: nil,
            groupType: .tyranny,
            commitment: internallyConsistent
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-onchain-mismatch",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty,
                      "Tyranny invitation must be rejected when on-chain commitment doesn't match")
    }

    func test_invitation_tyranny_rejectsWhenInternalRecomputeMismatch() async throws {
        // Payload claims a commitment that doesn't equal
        // Common.merkleRoot(payload.members). Internally inconsistent;
        // reject regardless of what's on chain.
        let groupID = Data(repeating: 0x42, count: 32)
        let bogusCommitment = Data(repeating: 0xC1, count: 32)
        // Even if the chain agrees with the bogus commitment, the
        // internal-recompute check must catch the lie.
        chainState.setNext(commitment: bogusCommitment, epoch: 0)
        let payload = makeInvitationPayload(
            groupID: groupID,
            name: "Family",
            memberProfiles: nil,
            groupType: .tyranny,
            commitment: bogusCommitment
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-internal-mismatch",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty,
                      "Tyranny invitation must be rejected when recomputed root != claimed commitment")
    }

    func test_announcement_tyranny_rejectsWhenOnchainMismatch() async throws {
        // Tyranny announcement carries a claimed commitment +
        // epoch. If on-chain disagrees, drop the announcement
        // (forged by someone other than admin, or stale).
        let groupID = Data(repeating: 0xAB, count: 32)
        let adminEd25519Hex = "ed".repeated(32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [:],
            adminEd25519PubkeyHex: adminEd25519Hex,
            groupType: .tyranny
        )

        let claimedCommitment = Data(repeating: 0xC1, count: 32)
        // Chain disagrees.
        chainState.setNext(commitment: Data(repeating: 0xFF, count: 32), epoch: 1)

        let member = try MemberAnnouncementPayload.AnnouncedMember(
            blsPub: Data(repeating: 0xBB, count: 48),
            inboxPub: Data(repeating: 0x33, count: 32),
            alias: "Bob",
            sendingPub: Data(repeating: 0xEE, count: 32)
        )
        let payload = try MemberAnnouncementPayload(
            version: 1,
            groupId: groupID,
            newMember: member,
            adminAlias: "Alice",
            commitment: claimedCommitment,
            epoch: 1
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-announce-mismatch",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertNil(after.first?.memberProfiles["bb".repeated(48)],
                     "Tyranny announcement must be rejected when on-chain commitment doesn't match")
    }

    // MARK: - Invitation materialization path

    func test_invitation_materializesLocalGroup_withSelfEntry() async throws {
        // Joiner-side: receive a fresh invitation for a group that
        // doesn't exist locally. Dispatcher materializes a ChatGroup
        // and adds the receiver's own profile to memberProfiles.
        let creatorBlsHex = "11".repeated(48)
        let creatorProfile = MemberProfile(
            alias: "Alice",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: Data(repeating: 0xEE, count: 32)
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
            inboxPublicKey: Data(repeating: 0xBB, count: 32),
            sendingPublicKey: Data(repeating: 0xCC, count: 32)
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: [selfSummary]),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
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
            inboxPublicKey: Data(repeating: 0xCC, count: 32),
            sendingPublicKey: Data(repeating: 0xDD, count: 32)
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: [selfSummary]),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
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
                inboxPublicKey: Data(repeating: 0x44, count: 32),
                sendingPubkey: Data(repeating: 0xEE, count: 32)
            )]
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
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
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
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
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
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
        memberProfiles: [String: MemberProfile],
        adminEd25519PubkeyHex: String? = nil,
        groupType: SEPGroupType = .anarchy,
        avatarJPEG: Data? = nil,
        invitationMessage: String? = nil,
        owner: IdentityID? = nil
    ) async {
        // Default to .anarchy so the existing dispatcher tests skip
        // PR 13b's Tyranny-only on-chain commitment verification.
        // Tests that specifically exercise Tyranny verification opt
        // in via the parameter and seed `chainState` accordingly.
        let group = ChatGroup(
            id: groupID.map { String(format: "%02x", $0) }.joined(),
            ownerIdentityID: owner ?? self.owner,
            name: "Family",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            members: [],
            memberProfiles: memberProfiles,
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: nil,
            tier: .small,
            groupType: groupType,
            adminPubkeyHex: nil,
            adminEd25519PubkeyHex: adminEd25519PubkeyHex,
            isPublishedOnChain: true,
            avatarJPEG: avatarJPEG,
            invitationMessage: invitationMessage
        )
        _ = await groups.insert(group)
    }

    // MARK: - Group rules

    func test_announcement_carriesTheJoinersAgreementToEveryMember() async throws {
        // The claim the whole feature rests on: an agreement is
        // checkable by any member, not only the founder who admitted
        // them. Everyone but that founder learns it from here.
        let groupID = Data(repeating: 0xAB, count: 32)
        let rules = "Be kind. No links."
        let joinerKey = Curve25519.Signing.PrivateKey()
        let joinerSendingPub = joinerKey.publicKey.rawRepresentation
        let signature = try joinerKey.signature(for: GroupRules.statement(
            groupID: groupID,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: joinerSendingPub
        ))
        let creator = MemberProfile(
            alias: "Alice",
            inboxPublicKey: Data(repeating: 0x10, count: 32),
            sendingPubkey: Data(repeating: 0xEE, count: 32)
        )
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["aa".repeated(48): creator],
            invitationMessage: rules
        )

        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "bb".repeated(48),
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice",
            joinerSendingPub: joinerSendingPub,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: signature,
            rulesText: rules
        ))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: FakeInvitationEnvelopeDecrypter(
                mode: .fixed(plaintext),
                senderEd25519PublicKey: Data(repeating: 0xEE, count: 32)
            ),
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )

        await dispatcher.dispatch(
            messageID: "msg-rules",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        let updated = try XCTUnwrap(after.first { $0.groupIDData == groupID })
        let joiner = try XCTUnwrap(updated.memberProfiles["bb".repeated(48)])
        XCTAssertEqual(joiner.rulesText, rules,
                       "the wording has to travel with the bytes it covers")
        XCTAssertTrue(
            joiner.agreedToRules(groupID: groupID),
            "and an existing member must be able to check it themselves"
        )
        XCTAssertEqual(updated.rulesStanding(ofMemberWith: "bb".repeated(48)), .signed)
    }

    func test_announcement_fromAnOlderBuild_carriesNoAgreementAndSaysSo() async throws {
        let groupID = Data(repeating: 0xAB, count: 32)
        // Left as the fixture's `.anarchy`: Tyranny announcements go
        // through on-chain commitment verification this suite doesn't
        // seed. So this asserts what the announcement *carried* —
        // nothing — and leaves what a group type makes of that to the
        // standing tests either side of it.
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["aa".repeated(48): MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: Data(repeating: 0xEE, count: 32)
            )],
            invitationMessage: "Be kind. No links."
        )
        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "bb".repeated(48),
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice"
        ))
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: FakeInvitationEnvelopeDecrypter(
                mode: .fixed(plaintext),
                senderEd25519PublicKey: Data(repeating: 0xEE, count: 32)
            ),
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-legacy",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        let updated = try XCTUnwrap(after.first { $0.groupIDData == groupID })
        let joiner = try XCTUnwrap(updated.memberProfiles["bb".repeated(48)])
        XCTAssertNil(joiner.rulesSignature)
        XCTAssertNil(joiner.rulesText)
    }

    func test_aMemberWhoSignedNothing_inAGroupThatCollectsAgreements_didNotSign() async throws {
        // The other half of the pair: where agreements *are* collected,
        // an empty record means what it says.
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["bb".repeated(48): MemberProfile(
                alias: "Bob",
                inboxPublicKey: Data(repeating: 0x33, count: 32),
                sendingPubkey: Data(repeating: 0xEE, count: 32)
            )],
            groupType: .tyranny,
            invitationMessage: "Be kind. No links."
        )
        let all = await groups.currentGroups()
        let group = try XCTUnwrap(all.first { $0.groupIDData == groupID })
        XCTAssertEqual(group.rulesStanding(ofMemberWith: "bb".repeated(48)), .didNotSign)
    }

    func test_aGroupTypeWithNoJoinApproval_marksNobodyAsHavingDeclined() async throws {
        // Anarchy and one-on-one have no join request and no admin, so
        // `.author` — keyed on `adminPubkeyHex`, nil for both — would
        // have marked every member, including whoever wrote the rules,
        // as having refused to sign them. Unreachable today, since
        // `.tyranny` is the only type `CreateGroupFlow` produces, and
        // pinned so it stays right when the others ship.
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(
            groupID: groupID,
            memberProfiles: ["aa".repeated(48): MemberProfile(
                alias: "Alice",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: Data(repeating: 0xEE, count: 32)
            )],
            groupType: .anarchy,
            invitationMessage: "Be kind. No links."
        )
        let all = await groups.currentGroups()
        let group = try XCTUnwrap(all.first { $0.groupIDData == groupID })
        XCTAssertEqual(group.rulesStanding(ofMemberWith: "aa".repeated(48)), .notCollected)
    }

    func test_aLaterInvitationWithoutTheSelfRow_doesNotEraseTheStoredAgreement() async throws {
        // The path re-runs on every relay replay, and an admin on a
        // build that predates the self row sends none. Copying the wire
        // straight over put the joiner back to "didn't sign" — the
        // defect this work exists to fix, reached by version skew.
        let groupID = Data(repeating: 0xAB, count: 32)
        let rules = "Be kind. No links."
        let selfKey = Curve25519.Signing.PrivateKey()
        let selfBlsHex = "cc".repeated(48)
        let signature = try selfKey.signature(for: GroupRules.statement(
            groupID: groupID,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: selfKey.publicKey.rawRepresentation
        ))
        // Already on the device, with the agreement recorded.
        await seedGroup(
            groupID: groupID,
            memberProfiles: [selfBlsHex: MemberProfile(
                alias: "Me",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: selfKey.publicKey.rawRepresentation,
                rulesHash: GroupRules.hash(rules),
                rulesSignature: signature,
                rulesText: rules
            )],
            invitationMessage: rules
        )

        // A second invitation for the same group, from an admin whose
        // build knows nothing about self rows.
        let invitation = GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "Family",
            members: [],
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: nil,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.anarchy.rawValue,
            adminPubkeyHex: nil,
            memberProfiles: nil,
            invitationMessage: rules
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: FakeInvitationEnvelopeDecrypter(
                mode: .fixed(try JSONEncoder().encode(invitation)),
                senderEd25519PublicKey: Data(repeating: 0xEE, count: 32)
            ),
            identities: StubIdentities(summaries: [
                IdentitySummary(
                    id: owner,
                    name: "Me",
                    blsPublicKey: Data(selfBlsHex.hexBytes),
                    inboxPublicKey: Data(repeating: 0x10, count: 32),
                    sendingPublicKey: selfKey.publicKey.rawRepresentation
                )
            ]),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-replay",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        let updated = try XCTUnwrap(after.first { $0.groupIDData == groupID })
        XCTAssertEqual(
            updated.rulesStanding(ofMemberWith: selfBlsHex), .signed,
            "an invitation that says nothing about our agreement must not delete it"
        )
    }

    func test_aReApprovalWithNoText_doesNotDowngradeAVerifiedAgreement() async throws {
        // Re-approving an old pending request after a rules edit sends
        // the signature with no text (`JoinRequestApprover.textCovering`).
        // Preferring the wire because it "has 64 bytes in it" turned an
        // agreement that verifies into one that can't be checked.
        let groupID = Data(repeating: 0xAB, count: 32)
        let rules = "Be kind. No links."
        let selfKey = Curve25519.Signing.PrivateKey()
        let selfBlsHex = "cc".repeated(48)
        let signature = try selfKey.signature(for: GroupRules.statement(
            groupID: groupID,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: selfKey.publicKey.rawRepresentation
        ))
        await seedGroup(
            groupID: groupID,
            memberProfiles: [selfBlsHex: MemberProfile(
                alias: "Me",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: selfKey.publicKey.rawRepresentation,
                rulesHash: GroupRules.hash(rules),
                rulesSignature: signature,
                rulesText: rules
            )],
            invitationMessage: rules
        )

        // The wire's row: same signature, no wording to check it against.
        let wireRow = MemberProfile(
            alias: "Me",
            inboxPublicKey: Data(repeating: 0x10, count: 32),
            sendingPubkey: selfKey.publicKey.rawRepresentation,
            rulesHash: GroupRules.hash(rules),
            rulesSignature: signature,
            rulesText: nil
        )
        await dispatchInvitation(
            groupID: groupID,
            rules: rules,
            profiles: [selfBlsHex: wireRow],
            selfBlsHex: selfBlsHex,
            selfSendingPub: selfKey.publicKey.rawRepresentation
        )

        let after = await groups.currentGroups()
        let updated = try XCTUnwrap(after.first { $0.groupIDData == groupID })
        XCTAssertEqual(
            updated.rulesStanding(ofMemberWith: selfBlsHex), .signed,
            "a record that proves something outranks one that doesn't"
        )
    }

    func test_theStoredFloorIsReadFromThisIdentitysRow() async throws {
        // Two identities on one device hold two rows for one group.
        // Looking the floor up by group alone read the other identity's
        // row and stamped its agreement onto this profile.
        let groupID = Data(repeating: 0xAB, count: 32)
        let rules = "Be kind. No links."
        let selfBlsHex = "cc".repeated(48)
        let otherKey = Curve25519.Signing.PrivateKey()
        let otherOwner = IdentityID()
        let otherSignature = try otherKey.signature(for: GroupRules.statement(
            groupID: groupID,
            rulesHash: GroupRules.hash(rules),
            joinerSendingPublicKey: otherKey.publicKey.rawRepresentation
        ))
        // The *other* identity's row for the same group, with an
        // agreement. Ours has none.
        await groups.setCurrentIdentity(otherOwner)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [selfBlsHex: MemberProfile(
                alias: "Someone else",
                inboxPublicKey: Data(repeating: 0x10, count: 32),
                sendingPubkey: otherKey.publicKey.rawRepresentation,
                rulesHash: GroupRules.hash(rules),
                rulesSignature: otherSignature,
                rulesText: rules
            )],
            invitationMessage: rules,
            owner: otherOwner
        )
        await groups.setCurrentIdentity(owner)

        await dispatchInvitation(
            groupID: groupID,
            rules: rules,
            profiles: nil,
            selfBlsHex: selfBlsHex,
            selfSendingPub: Data(repeating: 0xEE, count: 32)
        )

        let after = await groups.currentGroups()
        let mine = try XCTUnwrap(
            after.first { $0.groupIDData == groupID && $0.ownerIdentityID == owner }
        )
        XCTAssertNil(
            mine.memberProfiles[selfBlsHex]?.rulesSignature,
            "another identity's agreement must not become ours"
        )
    }

    /// Dispatches a `GroupInvitationPayload` as though it arrived
    /// sealed, with this suite's `owner` as the recipient.
    private func dispatchInvitation(
        groupID: Data,
        rules: String?,
        profiles: [String: MemberProfile]?,
        selfBlsHex: String,
        selfSendingPub: Data
    ) async {
        let invitation = GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "Family",
            members: [],
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: nil,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.anarchy.rawValue,
            adminPubkeyHex: nil,
            memberProfiles: profiles,
            invitationMessage: rules
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: FakeInvitationEnvelopeDecrypter(
                mode: .fixed((try? JSONEncoder().encode(invitation)) ?? Data()),
                senderEd25519PublicKey: Data(repeating: 0xEE, count: 32)
            ),
            identities: StubIdentities(summaries: [
                IdentitySummary(
                    id: owner,
                    name: "Me",
                    blsPublicKey: Data(selfBlsHex.hexBytes),
                    inboxPublicKey: Data(repeating: 0x10, count: 32),
                    sendingPublicKey: selfSendingPub
                )
            ]),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        await dispatcher.dispatch(
            messageID: "msg-\(UUID().uuidString)",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
    }

    private static func makeAnnouncement(
        groupID: Data,
        joinerBlsHex: String,
        joinerInboxByte: UInt8,
        joinerAlias: String,
        adminAlias: String,
        joinerSendingPub: Data = Data(repeating: 0xEE, count: 32),
        rulesHash: Data? = nil,
        rulesSignature: Data? = nil,
        rulesText: String? = nil
    ) throws -> MemberAnnouncementPayload {
        let blsPub = Data(joinerBlsHex.hexBytes)
        let member = try MemberAnnouncementPayload.AnnouncedMember(
            blsPub: blsPub,
            inboxPub: Data(repeating: joinerInboxByte, count: 32),
            alias: joinerAlias,
            sendingPub: joinerSendingPub,
            rulesHash: rulesHash,
            rulesSignature: rulesSignature,
            rulesText: rulesText
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

    private static func makeAvatar(groupID: Data, jpeg: Data?) -> GroupAvatarPayload {
        GroupAvatarPayload(
            version: 1,
            groupID: groupID,
            senderBlsPubkeyHex: "aa".repeated(48),
            sentAtMillis: 1_700_000_000_000,
            avatar: jpeg
        )
    }

    private static func encode(avatar: GroupAvatarPayload) throws -> Data {
        try JSONEncoder().encode(avatar)
    }
    private static func encode(name: GroupNamePayload) throws -> Data {
        try JSONEncoder().encode(name)
    }
    private static func makeName(groupID: Data, name: String) -> GroupNamePayload {
        GroupNamePayload(
            version: 1,
            groupID: groupID,
            senderBlsPubkeyHex: "aa".repeated(48),
            sentAtMillis: 1_700_000_000_000,
            name: name
        )
    }

    /// Compute the real Tyranny commitment for a given (members,
    /// epoch, salt) — i.e. `Poseidon(Poseidon(merkle_root, epoch),
    /// salt)`. Tests that exercise PR 13b's verifier need this so
    /// the dispatcher's recompute matches the wire-shipped value.
    static func makeRealTyrannyCommitment(
        members: [GovernanceMember],
        epoch: UInt64,
        salt: Data,
        tier: SEPTier
    ) throws -> Data {
        let root = try GroupCommitmentBuilder.computeMerkleRoot(
            members: members,
            tier: tier
        )
        return try GroupCommitmentBuilder.computePoseidonCommitment(
            poseidonRoot: root,
            epoch: epoch,
            salt: salt
        )
    }

    private func makeInvitationPayload(
        groupID: Data,
        name: String,
        memberProfiles: [String: MemberProfile]?,
        groupType: SEPGroupType = .anarchy,
        commitment: Data? = nil
    ) -> GroupInvitationPayload {
        GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: name,
            members: [],
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: commitment,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: groupType.rawValue,
            adminPubkeyHex: nil,
            peerBlsSecret: nil,
            memberProfiles: memberProfiles
        )
    }

    // MARK: - Invite offers + converge-forward (handshake)

    func test_offer_isQueuedForAcceptAndDoesNotMaterializeGroup() async throws {
        // A push offer must NOT materialize a group or land in the
        // opaque invitations queue — it becomes a structured
        // `PendingChat` row awaiting the user's explicit Accept.
        // Membership only follows accept + the admin's explicit approve.
        let offer = try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x44, count: 32),
            groupID: Data(repeating: 0x42, count: 32),
            groupName: "Maple Garden",
            inviterAlias: "Alice"
        )
        let plaintext = try JSONEncoder().encode(offer)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let spy = SpyPendingChats()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            pendingChats: spy
        )

        await dispatcher.dispatch(
            messageID: "msg-offer",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty, "an offer must NOT materialize a group")
        let storedCount = await invitationsStore.count
        XCTAssertEqual(storedCount, 0, "an offer is not an opaque invitation")
        let recorded = await spy.all()
        XCTAssertEqual(recorded.count, 1)
        // Keyed by (group, owner) rather than by the delivery: the same
        // offer replayed on the next reconnect is the same waiting room.
        XCTAssertEqual(
            recorded.first?.id,
            "\(String(repeating: "42", count: 32)):\(owner.rawValue.uuidString)"
        )
        XCTAssertEqual(recorded.first?.status, .offered)
        XCTAssertEqual(recorded.first?.introPublicKey, Data(repeating: 0x44, count: 32))
        XCTAssertEqual(recorded.first?.inviterAlias, "Alice")
        XCTAssertEqual(recorded.first?.groupName, "Maple Garden")
    }

    func test_invitation_tyranny_chainAhead_defersAndDoesNotMaterialize() async throws {
        // Option 2: a snapshot the chain has advanced past can't be
        // byte-verified, so it must NOT materialize — it's deferred to
        // the verifier, which asks the admin for the current state.
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)  // matches makeInvitationPayload
        let realCommitment = try Self.makeRealTyrannyCommitment(
            members: [], epoch: 0, salt: salt, tier: .small
        )
        // Chain ahead (epoch 5) — snapshot epoch 0 is stale.
        chainState.setNext(commitment: Data(repeating: 0x99, count: 32), epoch: 5)
        let payload = makeInvitationPayload(
            groupID: groupID,
            name: "Family",
            memberProfiles: nil,
            groupType: .tyranny,
            commitment: realCommitment
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let refresher = SpyGroupStateRefresher()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            groupStateRefresher: refresher
        )

        await dispatcher.dispatch(
            messageID: "msg-stale",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty, "a stale snapshot must not materialize")
        let deferred = await refresher.deferredGroupIDs()
        XCTAssertEqual(deferred, [groupID],
                       "stale invitation should be deferred to the verifier")
    }

    func test_invitation_tyranny_redelivery_skipsChainReadWhenAlreadyVerified() async throws {
        // The launch-time storm fix: a re-delivered invitation for an
        // already-materialized (commitment, epoch) must NOT hit the
        // relayer again. First delivery verifies (1 chain read) and
        // materializes; the identical replay short-circuits on the local
        // match, leaving the chain-read count at 1.
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)  // matches makeInvitationPayload
        let realCommitment = try Self.makeRealTyrannyCommitment(
            members: [], epoch: 0, salt: salt, tier: .small
        )
        chainState.setNext(commitment: realCommitment, epoch: 0)
        let payload = makeInvitationPayload(
            groupID: groupID,
            name: "Family",
            memberProfiles: nil,
            groupType: .tyranny,
            commitment: realCommitment
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )

        await dispatcher.dispatch(messageID: "mat-1", ownerIdentityID: owner,
                                  payload: Data("envelope".utf8), receivedAt: Date())
        await dispatcher.dispatch(messageID: "mat-1-replay", ownerIdentityID: owner,
                                  payload: Data("envelope".utf8), receivedAt: Date())

        let after = await groups.currentGroups()
        XCTAssertEqual(after.filter { $0.groupIDData == groupID }.count, 1,
                       "idempotent — still exactly one group")
        XCTAssertEqual(chainState.calls.count, 1,
                       "replay of an already-verified snapshot must not re-read the chain")
    }

    func test_invitation_tyranny_chainReadThrows_defersInsteadOfReject() async throws {
        // A throttled / unreachable relayer is not evidence of forgery.
        // The invitation must be deferred (retried via the admin-refresh
        // path), never silently dropped — that drop was the root cause of
        // "joiner only sees the chat after a restart".
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)
        let realCommitment = try Self.makeRealTyrannyCommitment(
            members: [], epoch: 0, salt: salt, tier: .small
        )
        chainState.setNextThrows(ChainReadError.noActiveRelayer)  // simulate throttle/offline
        let payload = makeInvitationPayload(
            groupID: groupID,
            name: "Family",
            memberProfiles: nil,
            groupType: .tyranny,
            commitment: realCommitment
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let refresher = SpyGroupStateRefresher()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            groupStateRefresher: refresher
        )

        await dispatcher.dispatch(messageID: "mat-throw", ownerIdentityID: owner,
                                  payload: Data("envelope".utf8), receivedAt: Date())

        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty, "unverifiable-now invitation must not materialize")
        // Still never rejected — but no longer routed to the admin.
        // A chain read this device couldn't make is not something the
        // admin can answer; asking them produced a reply, changed
        // nothing, and told the user "the admin is offline".
        let deferred = await refresher.deferredGroupIDs()
        XCTAssertTrue(deferred.isEmpty,
                      "a local read failure must not send a refresh request to the admin")
        let local = await refresher.locallyDeferred()
        XCTAssertEqual(local.map(\.groupID), [groupID],
                       "a chain-read failure must defer locally (retry), not reject+drop")
        XCTAssertEqual(local.map(\.status), [.chainNotConfigured],
                       "no relayer configured is a setup state, not a failed call")
    }

    /// The admin admitted somebody else before this joiner opened the
    /// app, so the chain has moved past the snapshot's epoch. The
    /// contract archives the last 64 entries, so the snapshot is still
    /// checkable against what was committed at *its* epoch — no
    /// round-trip to a phone that may be asleep.
    func test_invitation_tyranny_chainAhead_verifiesAgainstArchivedHistory() async throws {
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)
        let realCommitment = try Self.makeRealTyrannyCommitment(
            members: [], epoch: 1, salt: salt, tier: .small
        )
        // Chain is two epochs ahead of the invitation…
        chainState.setNext(commitment: Data(repeating: 0x09, count: 32), epoch: 3)
        // …but epoch 1 is still in the archive, with the same commitment.
        chainState.setHistory([
            (commitment: Data(repeating: 0x08, count: 32), epoch: 0),
            (commitment: realCommitment, epoch: 1),
            (commitment: Data(repeating: 0x07, count: 32), epoch: 2)
        ])
        let payload = GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "Family",
            members: [],
            epoch: 1,
            salt: salt,
            commitment: realCommitment,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.tyranny.rawValue,
            adminPubkeyHex: nil
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let refresher = SpyGroupStateRefresher()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            groupStateRefresher: refresher
        )

        await dispatcher.dispatch(messageID: "mat-ahead", ownerIdentityID: owner,
                                  payload: Data("envelope".utf8), receivedAt: Date())

        let after = await groups.currentGroups()
        XCTAssertEqual(after.count, 1, "an archived exact-epoch match verifies")
        let deferred = await refresher.deferredGroupIDs()
        XCTAssertTrue(deferred.isEmpty, "the admin must not be asked when history answers")
    }

    /// The same anti-forgery bar as the exact-epoch path: a snapshot
    /// whose commitment doesn't match what was archived at its epoch is
    /// a forgery, not a stale read.
    func test_invitation_tyranny_archivedEpochMismatch_isRejected() async throws {
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)
        let realCommitment = try Self.makeRealTyrannyCommitment(
            members: [], epoch: 1, salt: salt, tier: .small
        )
        chainState.setNext(commitment: Data(repeating: 0x09, count: 32), epoch: 3)
        chainState.setHistory([
            (commitment: Data(repeating: 0xAA, count: 32), epoch: 1)  // different
        ])
        let payload = GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "Family",
            members: [],
            epoch: 1,
            salt: salt,
            commitment: realCommitment,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.tyranny.rawValue,
            adminPubkeyHex: nil
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let refresher = SpyGroupStateRefresher()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            groupStateRefresher: refresher
        )

        await dispatcher.dispatch(messageID: "mat-forge", ownerIdentityID: owner,
                                  payload: Data("envelope".utf8), receivedAt: Date())

        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty, "a commitment that never was must not materialize")
        let local = await refresher.locallyDeferred()
        XCTAssertTrue(local.isEmpty, "a forgery is dropped, not parked for retry")
    }

    /// Older than the archive window: now the admin genuinely is the
    /// only source of current state, so the refresh request goes out.
    func test_invitation_tyranny_beyondHistoryWindow_asksTheAdmin() async throws {
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)
        let realCommitment = try Self.makeRealTyrannyCommitment(
            members: [], epoch: 1, salt: salt, tier: .small
        )
        chainState.setNext(commitment: Data(repeating: 0x09, count: 32), epoch: 400)
        chainState.setHistory([])  // epoch 1 long since evicted
        let payload = GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "Family",
            members: [],
            epoch: 1,
            salt: salt,
            commitment: realCommitment,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.tyranny.rawValue,
            adminPubkeyHex: nil
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let refresher = SpyGroupStateRefresher()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            groupStateRefresher: refresher
        )

        await dispatcher.dispatch(messageID: "mat-old", ownerIdentityID: owner,
                                  payload: Data("envelope".utf8), receivedAt: Date())

        let deferred = await refresher.deferredGroupIDs()
        XCTAssertEqual(deferred, [groupID], "past the window, only the admin can answer")
    }

    /// The joiner-side twin of the approve-side race: the group's own
    /// `create_group` hasn't settled. Says "settling", not "the admin is
    /// offline" — the admin is fine and can do nothing about it.
    func test_invitation_tyranny_groupNotOnChainYet_saysSettling() async throws {
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)
        let realCommitment = try Self.makeRealTyrannyCommitment(
            members: [], epoch: 0, salt: salt, tier: .small
        )
        chainState.setNextThrows(SEPError.invalidResponse(
            statusCode: 502,
            body: "HostError: Error(Contract, #5)"
        ))
        let payload = GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "Family",
            members: [],
            epoch: 0,
            salt: salt,
            commitment: realCommitment,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.tyranny.rawValue,
            adminPubkeyHex: nil
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let refresher = SpyGroupStateRefresher()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            groupStateRefresher: refresher
        )

        await dispatcher.dispatch(messageID: "mat-early", ownerIdentityID: owner,
                                  payload: Data("envelope".utf8), receivedAt: Date())

        let deferred = await refresher.deferredGroupIDs()
        XCTAssertTrue(deferred.isEmpty, "nobody to ask — the group simply isn't anchored yet")
        let local = await refresher.locallyDeferred()
        XCTAssertEqual(local.map(\.status), [.chainSettling])
    }

    func test_invitation_tyranny_chainBehind_defersInsteadOfReject() async throws {
        // Admin just anchored epoch 1 and immediately sent the snapshot;
        // our relayer read still lags at epoch 0. Treat as deferral, not a
        // hard reject — deferral never materializes without a later exact-
        // epoch match, so a forgery still can't slip in, while a real
        // lagging read recovers live instead of only on restart.
        let groupID = Data(repeating: 0x42, count: 32)
        let salt = Data(repeating: 0x66, count: 32)
        let realCommitment = try Self.makeRealTyrannyCommitment(
            members: [], epoch: 1, salt: salt, tier: .small
        )
        chainState.setNext(commitment: Data(repeating: 0x00, count: 32), epoch: 0)  // behind
        let payload = GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: Data(repeating: 0x55, count: 32),
            name: "Family",
            members: [],
            epoch: 1,
            salt: salt,
            commitment: realCommitment,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.tyranny.rawValue,
            adminPubkeyHex: nil
        )
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let refresher = SpyGroupStateRefresher()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            groupStateRefresher: refresher
        )

        await dispatcher.dispatch(messageID: "mat-behind", ownerIdentityID: owner,
                                  payload: Data("envelope".utf8), receivedAt: Date())

        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty, "chain-behind snapshot must not materialize unverified")
        let deferred = await refresher.deferredGroupIDs()
        XCTAssertTrue(deferred.isEmpty,
                      "a lagging read resolves by re-reading, not by asking the admin")
        let local = await refresher.locallyDeferred()
        XCTAssertEqual(local.map(\.groupID), [groupID],
                       "chain-behind must defer (lagging read), not reject+drop")
        XCTAssertEqual(local.map(\.status), [.chainSettling])
    }

    func test_announcement_tyranny_knownMember_skipsChainRead() async throws {
        // Re-delivered announcement for a member we already have must
        // dedup BEFORE the chain read, so inbox replays don't storm the
        // relayer.
        let groupID = Data(repeating: 0xAB, count: 32)
        let bobBlsHex = "bb".repeated(48)
        await seedGroup(
            groupID: groupID,
            memberProfiles: [bobBlsHex: MemberProfile(
                alias: "Bob",
                inboxPublicKey: Data(repeating: 0x33, count: 32),
                sendingPubkey: Data(repeating: 0xEE, count: 32)
            )],
            adminEd25519PubkeyHex: "ed".repeated(32),
            groupType: .tyranny
        )
        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: bobBlsHex,
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xED, count: 32)
        )
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )

        await dispatcher.dispatch(messageID: "ann-known", ownerIdentityID: owner,
                                  payload: Data("envelope".utf8), receivedAt: Date())

        XCTAssertEqual(chainState.calls.count, 0,
                       "known-member announcement must dedup before reading the chain")
    }

    func test_refreshRequest_routedToVerifier() async throws {
        // An inbound GroupStateRefreshRequest is delegated to the
        // verifier (admin side) and never materializes / stores anything.
        let groupID = Data(repeating: 0x42, count: 32)
        let req = try GroupStateRefreshRequest(
            groupID: groupID,
            requesterInboxPublicKey: Data(repeating: 0x01, count: 32),
            requesterBlsPublicKey: Data(repeating: 0x02, count: 48)
        )
        let plaintext = try JSONEncoder().encode(req)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xAB, count: 32)
        )
        let refresher = SpyGroupStateRefresher()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            groupStateRefresher: refresher
        )

        await dispatcher.dispatch(
            messageID: "msg-refresh",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )

        let handled = await refresher.handledRefreshGroupIDs()
        XCTAssertEqual(handled, [groupID])
        let after = await groups.currentGroups()
        XCTAssertTrue(after.isEmpty)
        let storedCount = await invitationsStore.count
        XCTAssertEqual(storedCount, 0)
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

// MARK: - Pending-chats spy

private actor SpyPendingChats: PendingChatRecording {
    private(set) var recorded: [PendingChat] = []

    @discardableResult
    func record(_ chat: PendingChat) async -> PendingChatWriteOutcome {
        recorded.append(chat)
        return .inserted
    }

    func all() -> [PendingChat] { recorded }
}

// MARK: - Group-state refresher spy

private actor SpyGroupStateRefresher: GroupStateRefreshing {
    private var deferred: [Data] = []
    private var handled: [Data] = []
    /// Snapshots parked without asking the admin, with the reason. The
    /// distinction is the point of the split: a refresh request that
    /// goes out for a failure the admin can't fix is the bug.
    private var deferredLocally: [(groupID: Data, status: PendingGroupVerification.Status)] = []

    func deferVerification(invitation: GroupInvitationPayload, ownerIdentityID: IdentityID) async {
        deferred.append(invitation.groupID)
    }
    func deferLocally(
        invitation: GroupInvitationPayload,
        ownerIdentityID: IdentityID,
        senderEd25519PublicKey: Data?,
        status: PendingGroupVerification.Status
    ) async {
        deferredLocally.append((invitation.groupID, status))
    }
    func handleRefreshRequest(
        _ request: GroupStateRefreshRequest,
        ownerIdentityID: IdentityID,
        requesterEd25519: Data?
    ) async {
        handled.append(request.groupID)
    }
    func deferredGroupIDs() -> [Data] { deferred }
    func handledRefreshGroupIDs() -> [Data] { handled }
    func locallyDeferred() -> [(groupID: Data, status: PendingGroupVerification.Status)] {
        deferredLocally
    }
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
    func save(_ record: IncomingInvitationRecord) -> InvitationSaveOutcome {
        guard rows[record.id] == nil else { return .duplicate }
        rows[record.id] = record
        return .saved
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

// MARK: - PR 13b chain-state stub

/// Stub `ChainStateReading`. Tests configure `nextResult` per call
/// to drive accept / reject paths. Default = throws (which the
/// dispatcher treats as "couldn't verify, reject" — the safe
/// default for tests that don't care about the chain leg).
final class DispatcherStubChainState: ChainStateReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _nextResult: Result<SEPCommitmentEntry, Error> = .failure(
        ChainReadError.noActiveRelayer
    )
    private var _calls: [Data] = []

    var calls: [Data] { lock.withLock { _calls } }

    func setNext(commitment: Data, epoch: UInt64) {
        let entry = SEPCommitmentEntry(
            commitment: commitment,
            epoch: epoch,
            timestamp: 0,
            tier: 0,
            active: nil
        )
        lock.withLock { _nextResult = .success(entry) }
    }

    func setNextThrows(_ error: Error) {
        lock.withLock { _nextResult = .failure(error) }
    }

    func tyrannyCommitment(groupID: Data) async throws -> SEPCommitmentEntry {
        let result: Result<SEPCommitmentEntry, Error> = lock.withLock {
            _calls.append(groupID)
            return _nextResult
        }
        return try result.get()
    }

    private var _history: Result<[SEPCommitmentEntry], Error> = .success([])
    private var _historyCalls: [Data] = []

    var historyCalls: [Data] { lock.withLock { _historyCalls } }

    /// Archived entries the contract would return for superseded epochs.
    func setHistory(_ entries: [(commitment: Data, epoch: UInt64)]) {
        let mapped = entries.map {
            SEPCommitmentEntry(
                commitment: $0.commitment,
                epoch: $0.epoch,
                timestamp: 0,
                tier: 0,
                active: nil
            )
        }
        lock.withLock { _history = .success(mapped) }
    }

    func setHistoryThrows(_ error: Error) {
        lock.withLock { _history = .failure(error) }
    }

    func tyrannyHistory(groupID: Data, maxEntries: UInt32) async throws -> [SEPCommitmentEntry] {
        let result: Result<[SEPCommitmentEntry], Error> = lock.withLock {
            _historyCalls.append(groupID)
            return _history
        }
        return try result.get()
    }
}
