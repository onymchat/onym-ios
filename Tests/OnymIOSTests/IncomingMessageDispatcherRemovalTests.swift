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
        identities: [IdentitySummary] = [],
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
            identities: RemovalStubIdentities(summaries: identities),
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
