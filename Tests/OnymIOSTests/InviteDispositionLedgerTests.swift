import XCTest
@testable import OnymIOS

/// PR-6 of the reconnect design: a Nostr relay may re-serve an invite
/// offer forever, so the client owns a durable record of what the user
/// already decided. Covers the ledger's monotonic state machine +
/// persistence, and the dispatcher's drop-at-the-door enforcement.
final class InviteDispositionLedgerTests: XCTestCase {
    private let owner = IdentityID()
    private let groupID = Data(repeating: 0x42, count: 32)

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    // MARK: - Ledger semantics

    func test_record_isMonotonic_reofferCannotDowngradeRequested() async {
        let ledger = InviteDispositionLedger(defaults: isolatedDefaults())
        await ledger.record(.requested, owner: owner, groupID: groupID, groupName: "G", inviterAlias: "A")
        await ledger.record(.offered, owner: owner, groupID: groupID, groupName: "G", inviterAlias: "A")
        let state = await ledger.disposition(owner: owner, groupID: groupID)
        XCTAssertEqual(state, .requested, "a re-delivered offer must not downgrade requested")
    }

    func test_joined_isTerminal() async {
        let ledger = InviteDispositionLedger(defaults: isolatedDefaults())
        await ledger.record(.joined, owner: owner, groupID: groupID, groupName: "G", inviterAlias: nil)
        await ledger.record(.requested, owner: owner, groupID: groupID, groupName: "G", inviterAlias: nil)
        let state = await ledger.disposition(owner: owner, groupID: groupID)
        XCTAssertEqual(state, .joined)
    }

    func test_declinedThenJoined_upgrades() async {
        // The admin's approval can land after a local dismiss — joined
        // always wins.
        let ledger = InviteDispositionLedger(defaults: isolatedDefaults())
        await ledger.record(.declined, owner: owner, groupID: groupID, groupName: "G", inviterAlias: nil)
        await ledger.record(.joined, owner: owner, groupID: groupID, groupName: "G", inviterAlias: nil)
        let state = await ledger.disposition(owner: owner, groupID: groupID)
        XCTAssertEqual(state, .joined)
    }

    func test_persistsAcrossInstances() async {
        let defaults = isolatedDefaults()
        let ledger = InviteDispositionLedger(defaults: defaults)
        await ledger.record(.requested, owner: owner, groupID: groupID, groupName: "Maple", inviterAlias: "Alice")

        let reloaded = InviteDispositionLedger(defaults: defaults)
        let state = await reloaded.disposition(owner: owner, groupID: groupID)
        XCTAssertEqual(state, .requested, "an accepted invite must survive relaunch")
    }

    func test_removeForOwner_cascades() async {
        let ledger = InviteDispositionLedger(defaults: isolatedDefaults())
        let otherOwner = IdentityID()
        await ledger.record(.requested, owner: owner, groupID: groupID, groupName: nil, inviterAlias: nil)
        await ledger.record(.requested, owner: otherOwner, groupID: groupID, groupName: nil, inviterAlias: nil)

        await ledger.removeForOwner(owner)
        let removed = await ledger.disposition(owner: owner, groupID: groupID)
        let kept = await ledger.disposition(owner: otherOwner, groupID: groupID)
        XCTAssertNil(removed)
        XCTAssertEqual(kept, .requested, "other identities' rows must be untouched")
    }

    func test_snapshots_filterByCurrentIdentity() async throws {
        let ledger = InviteDispositionLedger(defaults: isolatedDefaults())
        let otherOwner = IdentityID()
        await ledger.record(.requested, owner: owner, groupID: groupID, groupName: "Mine", inviterAlias: nil)
        await ledger.record(.requested, owner: otherOwner, groupID: groupID, groupName: "Theirs", inviterAlias: nil)
        await ledger.setCurrentIdentity(owner)

        var iterator = ledger.snapshots.makeAsyncIterator()
        let snapshot = await iterator.next()
        XCTAssertEqual(snapshot?.map(\.groupName), ["Mine"])
    }

    // MARK: - Dispatcher enforcement

    private func makeDispatcher(
        ledger: InviteDispositionLedger,
        spy: LedgerSpyPendingInvites,
        groups: GroupRepository = GroupRepository(store: SwiftDataGroupStore.inMemory()),
        offer: GroupInviteOfferPayload
    ) throws -> IncomingMessageDispatcher {
        IncomingMessageDispatcher(
            envelopeDecrypter: FakeInvitationEnvelopeDecrypter(
                mode: .fixed(try JSONEncoder().encode(offer))
            ),
            identities: LedgerStubIdentities(),
            groupRepository: groups,
            invitationsRepository: IncomingInvitationsRepository(store: SwiftDataInvitationStore.inMemory()),
            chainState: LedgerThrowingChainState(),
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            pendingInvites: spy,
            inviteDispositions: ledger
        )
    }

    private func makeOffer() throws -> GroupInviteOfferPayload {
        try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x44, count: 32),
            groupID: groupID,
            groupName: "Maple Garden",
            inviterAlias: "Alice"
        )
    }

    func test_freshOffer_isQueuedAndRecordedOffered() async throws {
        let ledger = InviteDispositionLedger(defaults: isolatedDefaults())
        let spy = LedgerSpyPendingInvites()
        let dispatcher = try makeDispatcher(ledger: ledger, spy: spy, offer: makeOffer())

        await dispatcher.dispatchAndDrain(
            messageID: "m1", ownerIdentityID: owner,
            payload: Data("envelope".utf8), receivedAt: Date()
        )
        let recorded = await spy.all()
        XCTAssertEqual(recorded.count, 1)
        let state = await ledger.disposition(owner: owner, groupID: groupID)
        XCTAssertEqual(state, .offered)
    }

    func test_redeliveredOffer_afterRequested_isDropped() async throws {
        let ledger = InviteDispositionLedger(defaults: isolatedDefaults())
        await ledger.record(.requested, owner: owner, groupID: groupID, groupName: nil, inviterAlias: nil)
        let spy = LedgerSpyPendingInvites()
        let dispatcher = try makeDispatcher(ledger: ledger, spy: spy, offer: makeOffer())

        await dispatcher.dispatchAndDrain(
            messageID: "m-redelivered", ownerIdentityID: owner,
            payload: Data("envelope".utf8), receivedAt: Date()
        )
        let recorded = await spy.all()
        XCTAssertTrue(recorded.isEmpty,
                      "an offer for an already-requested invite must be dropped at the door")
    }

    func test_redeliveredOffer_afterDeclined_isDropped() async throws {
        let ledger = InviteDispositionLedger(defaults: isolatedDefaults())
        await ledger.record(.declined, owner: owner, groupID: groupID, groupName: nil, inviterAlias: nil)
        let spy = LedgerSpyPendingInvites()
        let dispatcher = try makeDispatcher(ledger: ledger, spy: spy, offer: makeOffer())

        await dispatcher.dispatchAndDrain(
            messageID: "m-redelivered", ownerIdentityID: owner,
            payload: Data("envelope".utf8), receivedAt: Date()
        )
        let recorded = await spy.all()
        XCTAssertTrue(recorded.isEmpty, "declined is sticky across re-deliveries")
    }

    func test_offerForLocallyExistingGroup_isDroppedAndMarkedJoined() async throws {
        // The blink loop's root case: the group already materialized;
        // the re-served offer must be dropped and the ledger updated so
        // even the group's later deletion can't resurrect the offer.
        let ledger = InviteDispositionLedger(defaults: isolatedDefaults())
        let groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        _ = await groups.insert(ChatGroup(
            id: groupID.map { String(format: "%02x", $0) }.joined(),
            ownerIdentityID: owner,
            name: "Maple Garden",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            members: [], memberProfiles: [:],
            epoch: 0, salt: Data(repeating: 0x66, count: 32),
            commitment: nil, tier: .small, groupType: .tyranny,
            adminPubkeyHex: nil, adminEd25519PubkeyHex: nil,
            isPublishedOnChain: true
        ))
        let spy = LedgerSpyPendingInvites()
        let dispatcher = try makeDispatcher(ledger: ledger, spy: spy, groups: groups, offer: makeOffer())

        await dispatcher.dispatchAndDrain(
            messageID: "m1", ownerIdentityID: owner,
            payload: Data("envelope".utf8), receivedAt: Date()
        )
        let recorded = await spy.all()
        XCTAssertTrue(recorded.isEmpty, "an offer for a joined group must never re-enter the inbox")
        let state = await ledger.disposition(owner: owner, groupID: groupID)
        XCTAssertEqual(state, .joined)
    }
}

// MARK: - Test doubles

private actor LedgerSpyPendingInvites: PendingInvitesRecording {
    private var recorded: [PendingInvite] = []
    func record(_ invite: PendingInvite) async { recorded.append(invite) }
    func all() -> [PendingInvite] { recorded }
}

private struct LedgerStubIdentities: IdentitiesProviding {
    func currentIdentities() async -> [IdentitySummary] { [] }
}

private struct LedgerThrowingChainState: ChainStateReading {
    func tyrannyCommitment(groupID: Data) async throws -> SEPCommitmentEntry {
        throw URLError(.unsupportedURL)
    }
}
