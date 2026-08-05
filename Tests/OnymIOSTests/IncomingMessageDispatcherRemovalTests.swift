import XCTest
@testable import OnymIOS

/// Behavioral tests for the `IncomingMessageDispatcher` member-removal
/// fast path: remaining-member apply (tombstone + secret rotation),
/// self-removal (`ChatGroup.membershipRevoked`), the admin-signature
/// gate, the on-chain converge-forward check, idempotent re-delivery,
/// and the chain-behind bounded retry.
///
/// Mirrors `IncomingMessageDispatcherRemovalTest.kt` from
/// onym-android. The retry cases inject an inline scheduler + no-op
/// sleep so the 12s/24s production delays never run in tests.
@MainActor
final class IncomingMessageDispatcherRemovalTests: XCTestCase {

    private let groupID = Data(repeating: 0xAA, count: 32)

    private let adminSending = Data(repeating: 0x10, count: 32)
    private var adminSendingHex: String { String(repeating: "10", count: 32) }

    private let victimBls = Data(repeating: 0xBB, count: 48)
    private var victimHex: String { String(repeating: "bb", count: 48) }
    private let otherBls = Data(repeating: 0xCC, count: 48)
    private var otherHex: String { String(repeating: "cc", count: 48) }

    private let oldSecret = Data(repeating: 0x01, count: 32)
    private let oldSalt = Data(repeating: 0x02, count: 32)
    private let newSecret = Data(repeating: 0x03, count: 32)
    private let newSalt = Data(repeating: 0x04, count: 32)
    private let newCommitment = Data(repeating: 0x05, count: 32)

    private var groups: GroupRepository!
    private var invitations: IncomingInvitationsRepository!
    private var owner: IdentityID!

    override func setUp() async throws {
        try await super.setUp()
        groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        invitations = IncomingInvitationsRepository(store: InMemoryInvitationStore())
        owner = IdentityID()
        await groups.setCurrentIdentity(owner)
        _ = await groups.insert(makeGroup())
    }

    override func tearDown() async throws {
        groups = nil
        invitations = nil
        owner = nil
        try await super.tearDown()
    }

    // MARK: - remaining-member apply

    func test_removal_remainingMember_tombstonesAndRotatesSecrets() async throws {
        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(payload: payloadForMembers(), reader: reader)
        await dispatch(dispatcher)

        let updated = try await currentGroup()
        // Tombstoned, not deleted.
        let victim = try XCTUnwrap(updated.memberProfiles[victimHex])
        XCTAssertTrue(victim.revoked)
        // Other member untouched.
        XCTAssertEqual(updated.memberProfiles[otherHex]?.revoked, false)
        // Subtracted from the on-chain roster.
        XCTAssertFalse(updated.members.contains { $0.publicKeyCompressed == victimBls })
        // Rotated state applied.
        XCTAssertEqual(updated.epoch, 2)
        XCTAssertEqual(updated.groupSecret, newSecret)
        XCTAssertEqual(updated.salt, newSalt)
        XCTAssertEqual(updated.commitment, newCommitment)
        XCTAssertFalse(updated.membershipRevoked)
    }

    func test_removal_selfTarget_setsMembershipRevokedAndKeepsSecrets() async throws {
        // The receiving identity IS the victim; their payload variant
        // carries no secrets.
        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(
            payload: payloadForVictim(),
            identities: [selfSummary()],
            reader: reader
        )
        await dispatch(dispatcher)

        let updated = try await currentGroup()
        XCTAssertTrue(updated.membershipRevoked)
        // Nothing else moved: history-preserving, secrets untouched.
        XCTAssertEqual(updated.epoch, 1)
        XCTAssertEqual(updated.groupSecret, oldSecret)
        XCTAssertEqual(updated.salt, oldSalt)
        XCTAssertEqual(updated.members.count, 2)
        XCTAssertEqual(updated.memberProfiles[victimHex]?.revoked, false)
    }

    // MARK: - trust gates

    func test_removal_droppedWhenSignerIsNotAdmin() async throws {
        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(
            payload: payloadForMembers(),
            senderPub: Data(repeating: 0x77, count: 32),  // not the admin key
            reader: reader
        )
        await dispatch(dispatcher)
        try await assertUntouched()
        XCTAssertEqual(reader.calls, 0, "auth gate precedes the chain read")
    }

    func test_removal_droppedWhenNoSigner() async throws {
        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(
            payload: payloadForMembers(),
            senderPub: nil,
            reader: reader
        )
        await dispatch(dispatcher)
        try await assertUntouched()
    }

    func test_removal_droppedOnExactEpochCommitmentMismatch() async throws {
        let reader = SequencedChainReader([entry(Data(repeating: 0x66, count: 32), epoch: 2)])
        let dispatcher = try makeDispatcher(payload: payloadForMembers(), reader: reader)
        await dispatch(dispatcher)
        try await assertUntouched()
        XCTAssertEqual(reader.calls, 1)
    }

    func test_removal_acceptedWhenChainAhead() async throws {
        // Chain moved past the removal epoch (later joins landed) —
        // the admin-signed removal is still legitimate history.
        let reader = SequencedChainReader([entry(Data(repeating: 0x66, count: 32), epoch: 7)])
        let dispatcher = try makeDispatcher(payload: payloadForMembers(), reader: reader)
        await dispatch(dispatcher)
        let updated = try await currentGroup()
        XCTAssertEqual(updated.memberProfiles[victimHex]?.revoked, true)
    }

    func test_removal_acceptedOnExactEpochCommitmentMatch() async throws {
        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(payload: payloadForMembers(), reader: reader)
        await dispatch(dispatcher)
        let updated = try await currentGroup()
        XCTAssertEqual(updated.memberProfiles[victimHex]?.revoked, true)
    }

    func test_removal_chainBehindWithZeroRetries_isDropped() async throws {
        let reader = SequencedChainReader([entry(Data(repeating: 0x66, count: 32), epoch: 1)])
        let dispatcher = try makeDispatcher(
            payload: payloadForMembers(),
            reader: reader,
            maxRetries: 0
        )
        await dispatch(dispatcher)
        try await assertUntouched()
        XCTAssertEqual(reader.calls, 1)
    }

    // MARK: - chain-behind retry

    func test_removal_chainBehind_retriesAndAppliesOnceChainCatchesUp() async throws {
        // First read: chain still at the pre-removal epoch (the
        // caching reader's ≤10s-stale entry). Second read: caught up.
        let reader = SequencedChainReader([
            entry(Data(repeating: 0x66, count: 32), epoch: 1),
            entry(newCommitment, epoch: 2),
        ])
        let dispatcher = try makeDispatcher(
            payload: payloadForMembers(),
            reader: reader,
            inlineRetries: true
        )
        await dispatch(dispatcher)

        let updated = try await currentGroup()
        XCTAssertEqual(updated.memberProfiles[victimHex]?.revoked, true)
        XCTAssertEqual(reader.calls, 2)
    }

    func test_removal_chainStuckBehind_givesUpAfterMaxRetries() async throws {
        let reader = SequencedChainReader([entry(Data(repeating: 0x66, count: 32), epoch: 1)])
        let dispatcher = try makeDispatcher(
            payload: payloadForMembers(),
            reader: reader,
            inlineRetries: true
        )
        await dispatch(dispatcher)

        try await assertUntouched()
        // Initial attempt + removalMaxRetries (2) = 3 chain reads.
        XCTAssertEqual(reader.calls, 3)
    }

    func test_removal_chainReadThrows_retriesLikeChainBehind() async throws {
        // An unreachable relayer is not evidence of forgery, but a
        // stolen admin key must not shrink rosters offline — the read
        // failure retries (and here recovers on the second attempt).
        let reader = SequencedChainReader(
            [entry(newCommitment, epoch: 2)],
            failuresBeforeFirstEntry: 1
        )
        let dispatcher = try makeDispatcher(
            payload: payloadForMembers(),
            reader: reader,
            inlineRetries: true
        )
        await dispatch(dispatcher)
        let updated = try await currentGroup()
        XCTAssertEqual(updated.memberProfiles[victimHex]?.revoked, true)
        XCTAssertEqual(reader.calls, 2)
    }

    // MARK: - review regressions

    func test_removal_replayAfterReadmission_doesNotRollStateBack() async throws {
        // 1. Removal (epoch 2) applies.
        let reader = SequencedChainReader([
            entry(newCommitment, epoch: 2),
            // Later reads: chain moved on past the re-admission.
            entry(Data(repeating: 0x70, count: 32), epoch: 3),
        ])
        let dispatcher = try makeDispatcher(payload: payloadForMembers(), reader: reader)
        await dispatch(dispatcher, messageID: "m1")
        var group = try await currentGroup()
        XCTAssertEqual(group.memberProfiles[victimHex]?.revoked, true)

        // 2. Re-admission: the announcement path resets the tombstone
        //    and stamps the admission epoch (local group epoch stays at
        //    2 — announcements don't carry group state). Mirrors what
        //    applyAnnouncement writes.
        let postReadmissionSecret = Data(repeating: 0x71, count: 32)
        group.memberProfiles[victimHex] = group.memberProfiles[victimHex]?
            .withStatus(revoked: false, statusEpoch: 3)
        group.groupSecret = postReadmissionSecret
        _ = await groups.insert(group)

        // 3. The relay replays the OLD epoch-2 removal envelope. The
        //    chain (epoch 3) is ahead — without the local
        //    converge-forward guard this would re-tombstone the member
        //    and roll groupSecret/epoch back to the removal values.
        await dispatch(dispatcher, messageID: "m2")

        let final = try await currentGroup()
        XCTAssertEqual(final.memberProfiles[victimHex]?.revoked, false,
                       "re-admitted member must stay active")
        XCTAssertEqual(final.groupSecret, postReadmissionSecret,
                       "post-readmission secret must survive the replay")
        XCTAssertEqual(final.epoch, 2)
        // And the replay never even hit the chain (local guard fires first).
        XCTAssertEqual(reader.calls, 1)
    }

    func test_removal_outOfOrderDelivery_tombstonesBothWithoutRollingStateBack() async throws {
        // Relay dispatch order is ARRIVAL order: an offline device can
        // receive "remove other (epoch 3)" before "remove victim
        // (epoch 2)". Both must land — a single group-epoch guard would
        // drop the epoch-2 removal forever and leave the victim trusted.
        let laterCommitment = Data(repeating: 0x80, count: 32)
        let laterSecret = Data(repeating: 0x81, count: 32)
        let laterSalt = Data(repeating: 0x82, count: 32)
        let laterRemoval = try MemberRemovalPayload(
            version: 1,
            groupID: groupID,
            removedBlsHex: otherHex,
            commitment: laterCommitment,
            epoch: 3,
            sentAtMillis: 2_000,
            groupSecretNew: laterSecret,
            saltNew: laterSalt
        )
        // Chain is at the latest epoch throughout (both removals are
        // already anchored by the time this device reconnects).
        let reader = SequencedChainReader([entry(laterCommitment, epoch: 3)])

        // Newest-first replay: epoch 3 lands, advancing state.
        let laterDispatcher = try makeDispatcher(payload: laterRemoval, reader: reader)
        await dispatch(laterDispatcher, messageID: "m1")
        let afterLater = try await currentGroup()
        XCTAssertEqual(afterLater.memberProfiles[otherHex]?.revoked, true)
        XCTAssertEqual(afterLater.epoch, 3)

        // Then the older epoch-2 removal arrives.
        let earlierDispatcher = try makeDispatcher(payload: payloadForMembers(), reader: reader)
        await dispatch(earlierDispatcher, messageID: "m2")

        let final = try await currentGroup()
        // BOTH members tombstoned + dropped from the on-chain roster.
        XCTAssertEqual(final.memberProfiles[victimHex]?.revoked, true,
                       "stale-but-unseen removal must still tombstone")
        XCTAssertEqual(final.memberProfiles[otherHex]?.revoked, true)
        XCTAssertFalse(final.members.contains { $0.publicKeyCompressed == victimBls })
        XCTAssertFalse(final.members.contains { $0.publicKeyCompressed == otherBls })
        // Group state stays at the NEWER removal's values — the older
        // payload must not roll epoch / secrets backward.
        XCTAssertEqual(final.epoch, 3)
        XCTAssertEqual(final.groupSecret, laterSecret)
        XCTAssertEqual(final.salt, laterSalt)
        XCTAssertEqual(final.commitment, laterCommitment)
    }

    func test_removal_replayAfterOwnReadmission_doesNotRelockComposer() async throws {
        // Victim device: removed, then re-admitted (fresh invitation
        // stamps their own profile's statusEpoch). A replayed stale
        // self-removal must not re-set membershipRevoked.
        var readmitted = makeGroup()
        readmitted.membershipRevoked = false
        readmitted.epoch = 3
        readmitted.memberProfiles[victimHex] = readmitted.memberProfiles[victimHex]?
            .withStatus(revoked: false, statusEpoch: 3)
        _ = await groups.insert(readmitted)

        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(
            payload: payloadForVictim(),
            identities: [selfSummary()],
            reader: reader
        )
        await dispatch(dispatcher)

        let final = try await currentGroup()
        XCTAssertFalse(final.membershipRevoked,
                       "stale self-removal must not re-lock the thread")
        XCTAssertEqual(reader.calls, 0)
    }

    func test_removal_failsClosedWhenGroupHasNoStoredAdminKey() async throws {
        // A group materialized from an unsigned invitation stores no
        // admin Ed25519. isAuthorizedGroupMutation's any-current-member
        // fallback must NOT apply to a subtractive op — a member's
        // valid signature is not authority to evict another member.
        let memberSending = Data(repeating: 0x42, count: 32)
        var group = makeGroup()
        group.adminEd25519PubkeyHex = nil
        group.memberProfiles[otherHex] = MemberProfile(
            alias: "Other",
            inboxPublicKey: Data(repeating: 0x41, count: 32),
            sendingPubkey: memberSending
        )
        _ = await groups.insert(group)

        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(
            payload: payloadForMembers(),
            senderPub: memberSending,  // valid CURRENT member signature
            reader: reader
        )
        await dispatch(dispatcher)

        let after = try await currentGroup()
        XCTAssertEqual(after.memberProfiles[victimHex]?.revoked, false)
        XCTAssertEqual(after.epoch, 1)
        XCTAssertEqual(reader.calls, 0, "fails closed before any chain read")
    }

    func test_removal_droppedWhenSelfUnresolvable() async throws {
        // No resolvable self identity → can't classify self vs
        // remaining-member. The safe posture is drop (previously the
        // victim's own device would take the remaining-member branch
        // and delete itself).
        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(
            payload: payloadForMembers(),
            identities: [],
            reader: reader
        )
        await dispatch(dispatcher)
        try await assertUntouched()
        XCTAssertEqual(reader.calls, 0)
    }

    // MARK: - idempotency

    func test_removal_redeliveryBailsBeforeChainRead() async throws {
        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(payload: payloadForMembers(), reader: reader)
        await dispatch(dispatcher, messageID: "m1")
        await dispatch(dispatcher, messageID: "m2")

        // Second delivery must not have hit the relayer (launch-storm
        // protection) — one read total.
        XCTAssertEqual(reader.calls, 1)
        let updated = try await currentGroup()
        XCTAssertEqual(updated.memberProfiles[victimHex]?.revoked, true)
    }

    func test_removal_selfRedeliveryBailsWhenAlreadyRevoked() async throws {
        var revoked = makeGroup()
        revoked.membershipRevoked = true
        _ = await groups.insert(revoked)

        let reader = SequencedChainReader([entry(newCommitment, epoch: 2)])
        let dispatcher = try makeDispatcher(
            payload: payloadForVictim(),
            identities: [selfSummary()],
            reader: reader
        )
        await dispatch(dispatcher)
        XCTAssertEqual(reader.calls, 0)
    }

    // MARK: - helpers

    private func currentGroup() async throws -> ChatGroup {
        let all = await groups.currentGroups()
        return try XCTUnwrap(all.first { $0.groupIDData == groupID })
    }

    private func assertUntouched() async throws {
        let group = try await currentGroup()
        XCTAssertEqual(group.memberProfiles[victimHex]?.revoked, false)
        XCTAssertEqual(group.epoch, 1)
        XCTAssertEqual(group.groupSecret, oldSecret)
        XCTAssertFalse(group.membershipRevoked)
    }

    private func dispatch(
        _ dispatcher: IncomingMessageDispatcher,
        messageID: String = "m1"
    ) async {
        await dispatcher.dispatch(
            messageID: messageID,
            ownerIdentityID: owner,
            payload: Data("envelope".utf8),
            receivedAt: Date()
        )
    }

    private func makeDispatcher(
        payload: MemberRemovalPayload,
        senderPub: Data? = Data(repeating: 0x10, count: 32),
        identities: [IdentitySummary]? = nil,
        reader: SequencedChainReader,
        maxRetries: Int = 2,
        inlineRetries: Bool = false
    ) throws -> IncomingMessageDispatcher {
        let plaintext = try JSONEncoder().encode(payload)
        let decrypter = FakeInvitationEnvelopeDecrypter(
            mode: .fixed(plaintext),
            senderEd25519PublicKey: senderPub
        )
        var dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: decrypter,
            identities: RemovalStubIdentities(summaries: identities ?? [nonVictimSelf()]),
            groupRepository: groups,
            invitationsRepository: invitations,
            chainState: reader,
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory())
        )
        dispatcher.removalMaxRetries = maxRetries
        // No real 12s sleeps in tests.
        dispatcher.removalRetrySleep = { _ in }
        if inlineRetries {
            // Run the retry inline so `dispatch` only returns once the
            // bounded-retry loop has completed.
            dispatcher.removalRetryScheduler = { work in await work() }
        }
        return dispatcher
    }

    private func selfSummary() -> IdentitySummary {
        IdentitySummary(
            id: owner,
            name: "Me",
            blsPublicKey: victimBls,
            inboxPublicKey: Data(repeating: 0x21, count: 32),
            sendingPublicKey: Data(repeating: 0x22, count: 32)
        )
    }

    /// Default self-identity: a non-victim member, so the dispatcher
    /// can classify the removal (an unresolvable self now DROPS —
    /// see `test_removal_droppedWhenSelfUnresolvable`).
    private func nonVictimSelf() -> IdentitySummary {
        IdentitySummary(
            id: owner,
            name: "Me",
            blsPublicKey: Data(repeating: 0x99, count: 48),
            inboxPublicKey: Data(repeating: 0x21, count: 32),
            sendingPublicKey: Data(repeating: 0x22, count: 32)
        )
    }

    private func entry(_ commitment: Data, epoch: UInt64) -> SEPCommitmentEntry {
        SEPCommitmentEntry(
            commitment: commitment,
            epoch: epoch,
            timestamp: 0,
            tier: 0,
            active: nil
        )
    }

    private func payloadForMembers() throws -> MemberRemovalPayload {
        try MemberRemovalPayload(
            version: 1,
            groupID: groupID,
            removedBlsHex: victimHex,
            commitment: newCommitment,
            epoch: 2,
            sentAtMillis: 1_000,
            groupSecretNew: newSecret,
            saltNew: newSalt
        )
    }

    private func payloadForVictim() throws -> MemberRemovalPayload {
        try MemberRemovalPayload(
            version: 1,
            groupID: groupID,
            removedBlsHex: victimHex,
            commitment: newCommitment,
            epoch: 2,
            sentAtMillis: 1_000
        )
    }

    private func makeGroup() -> ChatGroup {
        ChatGroup(
            id: groupID.map { String(format: "%02x", $0) }.joined(),
            ownerIdentityID: owner,
            name: "Family",
            groupSecret: oldSecret,
            createdAt: Date(timeIntervalSince1970: 0),
            members: [
                GovernanceMember(
                    publicKeyCompressed: victimBls,
                    leafHash: Data(repeating: 0x0B, count: 32)
                ),
                GovernanceMember(
                    publicKeyCompressed: otherBls,
                    leafHash: Data(repeating: 0x0C, count: 32)
                ),
            ],
            memberProfiles: [
                victimHex: MemberProfile(
                    alias: "Victim",
                    inboxPublicKey: Data(repeating: 0x31, count: 32),
                    sendingPubkey: Data(repeating: 0x32, count: 32)
                ),
                otherHex: MemberProfile(
                    alias: "Other",
                    inboxPublicKey: Data(repeating: 0x41, count: 32),
                    sendingPubkey: Data(repeating: 0x42, count: 32)
                ),
            ],
            epoch: 1,
            salt: oldSalt,
            commitment: Data(repeating: 0x50, count: 32),
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: String(repeating: "de", count: 48),
            adminEd25519PubkeyHex: adminSendingHex,
            isPublishedOnChain: true
        )
    }
}

// MARK: - Test doubles

/// Programmable chain reader: serves `entries` in order, repeating the
/// last one, counting calls. Optionally throws for the first
/// `failuresBeforeFirstEntry` calls (unreachable-relayer simulation).
private final class SequencedChainReader: ChainStateReading, @unchecked Sendable {
    private let lock = NSLock()
    private let entries: [SEPCommitmentEntry]
    private let failuresBeforeFirstEntry: Int
    private var _calls = 0

    var calls: Int { lock.withLock { _calls } }

    init(_ entries: [SEPCommitmentEntry], failuresBeforeFirstEntry: Int = 0) {
        self.entries = entries
        self.failuresBeforeFirstEntry = failuresBeforeFirstEntry
    }

    func tyrannyCommitment(groupID: Data) async throws -> SEPCommitmentEntry {
        try lock.withLock {
            let call = _calls
            _calls += 1
            if call < failuresBeforeFirstEntry {
                throw ChainReadError.noActiveRelayer
            }
            let index = min(call - failuresBeforeFirstEntry, entries.count - 1)
            return entries[index]
        }
    }
}

private actor RemovalStubIdentities: IdentitiesProviding {
    private let summaries: [IdentitySummary]

    init(summaries: [IdentitySummary]) {
        self.summaries = summaries
    }

    func currentIdentities() -> [IdentitySummary] { summaries }
}
