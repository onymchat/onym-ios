import XCTest
@testable import OnymIOS
import OnymFoundation
import OnymIdentity
@testable import OnymGroup

/// Round-trip tests for `SwiftDataPendingAnchorStore` — the store whose
/// only job is to still have a salt after the process that drew it is
/// gone.
///
/// A member-add's salt is random, and until it was written down it
/// existed nowhere but that process's memory. A transaction that
/// reached the ledger while its answer did not reach the phone left the
/// chain committed to a value nothing could name, and the group could
/// never admit another member.
final class SwiftDataPendingAnchorStoreTests: XCTestCase {

    private let groupID = Data(repeating: 0xAB, count: 32)
    private let owner = IdentityID()

    private func anchor(
        epochOld: UInt64 = 3,
        joiner: UInt8 = 0xC1,
        salt: UInt8 = 0x5C,
        at seconds: TimeInterval = 0,
        groupID: Data? = nil,
        owner: IdentityID? = nil
    ) -> PendingAnchor {
        PendingAnchor(
            groupID: groupID ?? self.groupID,
            ownerIdentityID: owner ?? self.owner,
            epochOld: epochOld,
            joinerPublicKey: Data(repeating: joiner, count: 48),
            joinerLeafHash: Data(repeating: joiner &+ 1, count: 32),
            saltNew: Data(repeating: salt, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds)
        )
    }

    func test_recordThenPending_roundTrips() async throws {
        let store = SwiftDataPendingAnchorStore.inMemory()
        let written = anchor()

        try await store.record(written)
        let read = await store.pending(groupID: groupID, ownerIdentityID: owner)

        XCTAssertEqual(read, [written])
    }

    /// Each retry of the same join draws its own salt, and any of them
    /// could be the one that landed. Collapsing them on
    /// `(group, joiner, epoch)` would keep only the last — reliably the
    /// one that did not.
    func test_retriesOfTheSameJoinAreKeptSideBySide() async throws {
        let store = SwiftDataPendingAnchorStore.inMemory()
        try await store.record(anchor(salt: 0x11, at: 0))
        try await store.record(anchor(salt: 0x22, at: 60))

        let read = await store.pending(groupID: groupID, ownerIdentityID: owner)

        XCTAssertEqual(read.count, 2)
        // Newest first: the likeliest candidate is checked against the
        // chain before the older one.
        XCTAssertEqual(read[0].saltNew, Data(repeating: 0x22, count: 32))
        XCTAssertEqual(read[1].saltNew, Data(repeating: 0x11, count: 32))
    }

    /// `record` adds and never deletes.
    ///
    /// The tempting optimisation is to sweep older epochs here — the
    /// chain has left them. It is wrong: the reconcile retries from an
    /// adopted state *before* that state is persisted, so a sweep on
    /// write would delete the record naming the landed transaction
    /// while the group on disk still says the epoch before it. Crash
    /// there and the salt is gone for good.
    func test_recordingFromALaterEpoch_keepsTheEarlierOnes() async throws {
        let store = SwiftDataPendingAnchorStore.inMemory()
        try await store.record(anchor(epochOld: 3, salt: 0x11))
        try await store.record(anchor(epochOld: 4, salt: 0x22))

        let read = await store.pending(groupID: groupID, ownerIdentityID: owner)

        XCTAssertEqual(read.count, 2, "only a persisted advance may sweep")
        XCTAssertEqual(Set(read.map(\.epochOld)), [3, 4])
    }

    /// Two approvals from the same state are both live candidates.
    func test_recordingFromTheSameEpoch_keepsTheOthers() async throws {
        let store = SwiftDataPendingAnchorStore.inMemory()
        try await store.record(anchor(epochOld: 3, joiner: 0xC1))
        try await store.record(anchor(epochOld: 3, joiner: 0xD1))

        let read = await store.pending(groupID: groupID, ownerIdentityID: owner)
        XCTAssertEqual(read.count, 2)
    }

    /// The sweep boundary is inclusive of the epoch named and nothing
    /// past it. That is what lets the caller settle an advance by naming
    /// the epoch just left, while an attempt made *from* the new state —
    /// which may still be in flight — survives.
    func test_clearing_isInclusiveOfTheEpochNamedAndStopsThere() async throws {
        let store = SwiftDataPendingAnchorStore.inMemory()
        try await store.record(anchor(epochOld: 5, joiner: 0xC1))
        try await store.record(anchor(epochOld: 5, joiner: 0xD1))

        await store.clear(groupID: groupID, ownerIdentityID: owner, throughEpoch: 4)
        let survived = await store.pending(groupID: groupID, ownerIdentityID: owner)
        XCTAssertEqual(survived.count, 2, "epoch 5 is past the boundary")

        await store.clear(groupID: groupID, ownerIdentityID: owner, throughEpoch: 5)
        let swept = await store.pending(groupID: groupID, ownerIdentityID: owner)
        XCTAssertTrue(swept.isEmpty)
    }

    /// Rows are scoped to one identity's copy of the group. Two local
    /// identities can each hold a row for the same on-chain group, and
    /// one settling must not sweep the other's evidence.
    func test_recordsAreScopedToTheOwningIdentity() async throws {
        let store = SwiftDataPendingAnchorStore.inMemory()
        let other = IdentityID()
        try await store.record(anchor(owner: owner))
        try await store.record(anchor(owner: other))

        await store.clear(groupID: groupID, ownerIdentityID: owner, throughEpoch: 99)

        let mine = await store.pending(groupID: groupID, ownerIdentityID: owner)
        let theirs = await store.pending(groupID: groupID, ownerIdentityID: other)
        XCTAssertTrue(mine.isEmpty)
        XCTAssertEqual(theirs.count, 1)
    }

    /// Same, for two different groups held by one identity.
    func test_recordsAreScopedToTheGroup() async throws {
        let store = SwiftDataPendingAnchorStore.inMemory()
        let otherGroup = Data(repeating: 0xCD, count: 32)
        try await store.record(anchor(groupID: groupID))
        try await store.record(anchor(groupID: otherGroup))

        await store.clear(groupID: groupID, ownerIdentityID: owner, throughEpoch: 99)

        let swept = await store.pending(groupID: groupID, ownerIdentityID: owner)
        let kept = await store.pending(groupID: otherGroup, ownerIdentityID: owner)
        XCTAssertTrue(swept.isEmpty)
        XCTAssertEqual(kept.count, 1)
    }

    /// An epoch past `Int64.max` still orders correctly. Unreachable in
    /// practice — the counter moves once per member-add — but the column
    /// stores a bit pattern, and a sweep that compared it as a signed
    /// integer would delete exactly the rows it must keep.
    func test_epochsAboveTheSignedRangeStillSweepCorrectly() async throws {
        let store = SwiftDataPendingAnchorStore.inMemory()
        let high = UInt64(Int64.max) + 10
        try await store.record(anchor(epochOld: high))

        await store.clear(groupID: groupID, ownerIdentityID: owner, throughEpoch: high - 1)
        let survived = await store.pending(groupID: groupID, ownerIdentityID: owner)
        XCTAssertEqual(survived.count, 1, "a signed comparison would have swept this")

        await store.clear(groupID: groupID, ownerIdentityID: owner, throughEpoch: high)
        let swept = await store.pending(groupID: groupID, ownerIdentityID: owner)
        XCTAssertTrue(swept.isEmpty)
    }
}
