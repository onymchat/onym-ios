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

    func test_announcement_acceptedForGroupWithoutStoredAdmin_legacyFallback() async throws {
        // Legacy / pre-PR-9 group materialized without a stored
        // adminEd25519PubkeyHex. Best-effort acceptance: any
        // announcement that decrypts cleanly + names the group is
        // accepted, matching pre-PR-9 behavior.
        let groupID = Data(repeating: 0xAB, count: 32)
        await seedGroup(groupID: groupID, memberProfiles: [:], adminEd25519PubkeyHex: nil)
        let plaintext = try Self.encode(announcement: try Self.makeAnnouncement(
            groupID: groupID,
            joinerBlsHex: "bb".repeated(48),
            joinerInboxByte: 0x33,
            joinerAlias: "Bob",
            adminAlias: "Alice"
        ))
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: Data(repeating: 0xAA, count: 32)
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
            messageID: "msg-legacy-fallback",
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
        let after = await groups.currentGroups()
        XCTAssertEqual(after.first?.memberProfiles["bb".repeated(48)]?.alias, "Bob",
                       "legacy group accepts announcements (best-effort)")
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
        avatarJPEG: Data? = nil
    ) async {
        // Default to .anarchy so the existing dispatcher tests skip
        // PR 13b's Tyranny-only on-chain commitment verification.
        // Tests that specifically exercise Tyranny verification opt
        // in via the parameter and seed `chainState` accordingly.
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
            groupType: groupType,
            adminPubkeyHex: nil,
            adminEd25519PubkeyHex: adminEd25519PubkeyHex,
            isPublishedOnChain: true,
            avatarJPEG: avatarJPEG
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
            alias: joinerAlias,
            sendingPub: Data(repeating: 0xEE, count: 32)
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
        // opaque invitations queue — it's queued as a structured
        // PendingInvite for the user's explicit Accept. Membership only
        // follows accept + the admin's explicit approve.
        let offer = try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x44, count: 32),
            groupID: Data(repeating: 0x42, count: 32),
            groupName: "Maple Garden",
            inviterAlias: "Alice"
        )
        let plaintext = try JSONEncoder().encode(offer)
        let decrypter = FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext))
        let spy = SpyPendingInvites()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: StubIdentities(summaries: []),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: chainState,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            pendingInvites: spy
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
        XCTAssertEqual(recorded.first?.id, "msg-offer")
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
        let deferred = await refresher.deferredGroupIDs()
        XCTAssertEqual(deferred, [groupID],
                       "a chain-read failure must defer (retry), not reject+drop")
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
        XCTAssertEqual(deferred, [groupID],
                       "chain-behind must defer (lagging read), not reject+drop")
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

// MARK: - Pending-invites spy

private actor SpyPendingInvites: PendingInvitesRecording {
    private(set) var recorded: [PendingInvite] = []
    func record(_ invite: PendingInvite) async { recorded.append(invite) }
    func all() -> [PendingInvite] { recorded }
}

// MARK: - Group-state refresher spy

private actor SpyGroupStateRefresher: GroupStateRefreshing {
    private var deferred: [Data] = []
    private var handled: [Data] = []
    func deferVerification(invitation: GroupInvitationPayload, ownerIdentityID: IdentityID) async {
        deferred.append(invitation.groupID)
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
}
