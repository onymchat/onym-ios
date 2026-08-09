import XCTest
@testable import OnymIOS
import OnymFoundation
import OnymIdentity
import OnymChatsCore

/// Round-trip tests for `SwiftDataMessageStore`. Uses
/// `SwiftDataMessageStore.inMemory()` so the on-disk store under
/// Application Support isn't touched. Encrypted columns go through
/// the real `StorageEncryption` — same setup as
/// `SwiftDataGroupStoreTests`. Rows are scoped by `(id, owner)`, so
/// reads/mutations name the owning identity.
final class SwiftDataMessageStoreTests: XCTestCase {

    private var store: SwiftDataMessageStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataMessageStore.inMemory()
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    // MARK: - Round-trip

    func test_insertOrUpdate_thenList_roundtripsAllFields() async {
        let owner = IdentityID()
        let groupID = "aa".repeated(32)
        let msg = makeMessage(
            groupID: groupID,
            ownerIdentityID: owner,
            senderHex: "11".repeated(48),
            body: "hello",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: .outgoing,
            status: .pending,
            moderationAuthenticityProof: "c2lnbmF0dXJl"
        )

        let outcome = await store.insertOrUpdate(msg)
        XCTAssertEqual(outcome, .inserted)

        let listed = await store.list(groupID: groupID, ownerIDString: owner.rawValue.uuidString)
        XCTAssertEqual(listed.count, 1)
        let first = listed[0]
        XCTAssertEqual(first.id, msg.id)
        XCTAssertEqual(first.groupID, groupID)
        XCTAssertEqual(first.ownerIdentityID, owner)
        XCTAssertEqual(first.senderBlsPubkeyHex, "11".repeated(48))
        XCTAssertEqual(first.body, "hello")
        XCTAssertEqual(first.sentAt, msg.sentAt)
        XCTAssertEqual(first.direction, .outgoing)
        XCTAssertEqual(first.status, .pending)
        XCTAssertEqual(first.groupType, .tyranny)
        XCTAssertEqual(first.moderationAuthenticityProof, "c2lnbmF0dXJl")
        XCTAssertNil(first.replyToMessageID,
                     "a non-reply message round-trips with no reply target")
    }

    func test_insertOrUpdate_imageAttachment_roundtrips() async {
        let owner = IdentityID()
        let groupID = "aa".repeated(32)
        let attachment = ChatImageAttachment(
            sha256: "cd".repeated(32),
            mimeType: "image/jpeg",
            byteSize: 51_234,
            width: 1024,
            height: 768,
            encKey: Data(repeating: 0x7, count: 32),
            blurhash: "LEHV6nWB2yk8",
            server: "https://blossom.onym.app"
        )
        let msg = ChatMessage(
            id: UUID(),
            groupID: groupID,
            ownerIdentityID: owner,
            senderBlsPubkeyHex: "11".repeated(48),
            body: "caption",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: .outgoing,
            status: .sent,
            replyToMessageID: nil,
            groupType: .tyranny,
            imageAttachment: attachment
        )
        _ = await store.insertOrUpdate(msg)

        let listed = await store.list(groupID: groupID, ownerIDString: owner.rawValue.uuidString)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].imageAttachment, attachment)
        XCTAssertEqual(listed[0].body, "caption")
    }

    func test_insertOrUpdate_noAttachment_roundtripsAsNil() async {
        let msg = makeMessage(body: "text only")
        _ = await store.insertOrUpdate(msg)
        let listed = await store.list(
            groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString
        )
        XCTAssertNil(listed[0].imageAttachment)
        XCTAssertNil(listed[0].videoAttachment)
    }

    func test_insertOrUpdate_videoAttachment_roundtrips() async {
        let owner = IdentityID()
        let groupID = "aa".repeated(32)
        let attachment = ChatVideoAttachment(
            sha256: "ef".repeated(32),
            mimeType: "video/mp4",
            byteSize: 4_200_000,
            width: 1280,
            height: 720,
            durationSeconds: 12.5,
            encKey: Data(repeating: 0x9, count: 32),
            poster: ChatImageAttachment(
                sha256: "cd".repeated(32),
                mimeType: "image/jpeg",
                byteSize: 51_234,
                width: 1280,
                height: 720,
                encKey: Data(repeating: 0x7, count: 32),
                blurhash: "LEHV6nWB2yk8",
                server: "https://blossom.onym.app"
            ),
            server: "https://blossom.onym.app"
        )
        let msg = ChatMessage(
            id: UUID(),
            groupID: groupID,
            ownerIdentityID: owner,
            senderBlsPubkeyHex: "11".repeated(48),
            body: "caption",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: .outgoing,
            status: .sent,
            replyToMessageID: nil,
            groupType: .tyranny,
            videoAttachment: attachment
        )
        _ = await store.insertOrUpdate(msg)

        let listed = await store.list(groupID: groupID, ownerIDString: owner.rawValue.uuidString)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].videoAttachment, attachment)
        XCTAssertNil(listed[0].imageAttachment)
        XCTAssertEqual(listed[0].body, "caption")
    }

    func test_insertOrUpdate_replyRef_roundtrips() async {
        let groupID = "aa".repeated(32)
        let target = UUID()
        let reply = makeMessage(groupID: groupID, body: "agreed", replyToMessageID: target)

        _ = await store.insertOrUpdate(reply)

        let listed = await store.list(groupID: groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed.first?.replyToMessageID, target,
                       "the reply target id must survive the encrypted-store round-trip")
    }

    func test_insertOrUpdate_sameID_updatesInPlace() async {
        let msg = makeMessage(body: "draft", status: .pending)
        _ = await store.insertOrUpdate(msg)

        // Same id + owner, status flipped: should overwrite, not duplicate.
        let updated = ChatMessage(
            id: msg.id,
            groupID: msg.groupID,
            ownerIdentityID: msg.ownerIdentityID,
            senderBlsPubkeyHex: msg.senderBlsPubkeyHex,
            body: "draft",
            sentAt: msg.sentAt,
            direction: .outgoing,
            status: .sent,
            replyToMessageID: nil,
            groupType: .tyranny
        )
        let outcome = await store.insertOrUpdate(updated)
        XCTAssertEqual(outcome, .updated,
                       "second insert on same id+owner must report update, not insert")

        let listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].status, .sent)
    }

    /// Regression: the same wire message id received by two local
    /// identities keeps a row per identity — the second arrival must
    /// not steal (or flip the direction of) the first's row.
    func test_insertOrUpdate_sameID_twoOwners_keepsBothRows() async {
        let groupID = "aa".repeated(32)
        let sharedID = UUID()
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        let outgoing = makeMessage(
            id: sharedID, groupID: groupID, ownerIdentityID: ownerA,
            body: "mine", direction: .outgoing
        )
        let incoming = makeMessage(
            id: sharedID, groupID: groupID, ownerIdentityID: ownerB,
            body: "mine", direction: .incoming
        )

        let outcomeA = await store.insertOrUpdate(outgoing)
        let outcomeB = await store.insertOrUpdate(incoming)
        XCTAssertEqual(outcomeA, .inserted)
        XCTAssertEqual(outcomeB, .inserted,
                       "second owner is a fresh insert, not an in-place overwrite")

        let aRows = await store.list(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)
        let bRows = await store.list(groupID: groupID, ownerIDString: ownerB.rawValue.uuidString)
        XCTAssertEqual(aRows.map(\.direction), [.outgoing], "A's own message stays outgoing")
        XCTAssertEqual(bRows.map(\.direction), [.incoming], "B sees it as incoming")
    }

    // MARK: - list

    func test_list_filtersByGroupID() async {
        let groupA = "aa".repeated(32)
        let groupB = "bb".repeated(32)
        _ = await store.insertOrUpdate(makeMessage(groupID: groupA, body: "in A"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupB, body: "in B"))

        let inA = await store.list(groupID: groupA, ownerIDString: kOwner.rawValue.uuidString)
        let inB = await store.list(groupID: groupB, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(inA.count, 1)
        XCTAssertEqual(inB.count, 1)
        XCTAssertEqual(inA[0].body, "in A")
        XCTAssertEqual(inB[0].body, "in B")
    }

    func test_list_filtersByOwner() async {
        let groupID = "aa".repeated(32)
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        _ = await store.insertOrUpdate(makeMessage(groupID: groupID, ownerIdentityID: ownerA, body: "a"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupID, ownerIdentityID: ownerB, body: "b"))

        let a = await store.list(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)
        let b = await store.list(groupID: groupID, ownerIDString: ownerB.rawValue.uuidString)
        XCTAssertEqual(a.map(\.body), ["a"])
        XCTAssertEqual(b.map(\.body), ["b"])
    }

    // ─── search ───────────────────────────────────────────────────

    func test_search_matchesBodySubstring_caseInsensitive_newestFirst() async {
        let groupA = "aa".repeated(32)
        let groupB = "bb".repeated(32)
        _ = await store.insertOrUpdate(makeMessage(
            groupID: groupA, body: "Let's meet at noon",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)))
        _ = await store.insertOrUpdate(makeMessage(
            groupID: groupB, body: "MEETING moved to 3pm",
            sentAt: Date(timeIntervalSince1970: 1_700_000_500)))
        _ = await store.insertOrUpdate(makeMessage(
            groupID: groupA, body: "unrelated chatter",
            sentAt: Date(timeIntervalSince1970: 1_700_000_900)))

        let hits = await store.search(
            ownerIDString: kOwner.rawValue.uuidString, query: "meet", limit: 200
        )
        // Both "meet at noon" and "MEETING" match (case-insensitive),
        // newest first; "unrelated chatter" is excluded.
        XCTAssertEqual(hits.map(\.body), ["MEETING moved to 3pm", "Let's meet at noon"])
    }

    func test_search_isOwnerScoped() async {
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        _ = await store.insertOrUpdate(makeMessage(ownerIdentityID: ownerA, body: "secret plan A"))
        _ = await store.insertOrUpdate(makeMessage(ownerIdentityID: ownerB, body: "secret plan B"))

        let a = await store.search(ownerIDString: ownerA.rawValue.uuidString, query: "secret", limit: 200)
        XCTAssertEqual(a.map(\.body), ["secret plan A"])
    }

    func test_search_emptyQuery_returnsNothing() async {
        _ = await store.insertOrUpdate(makeMessage(body: "anything"))
        let hits = await store.search(ownerIDString: kOwner.rawValue.uuidString, query: "   ", limit: 200)
        XCTAssertTrue(hits.isEmpty)
    }

    func test_search_respectsLimit() async {
        for i in 0..<5 {
            _ = await store.insertOrUpdate(makeMessage(
                id: UUID(), body: "match \(i)",
                sentAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i))))
        }
        let hits = await store.search(ownerIDString: kOwner.rawValue.uuidString, query: "match", limit: 3)
        XCTAssertEqual(hits.count, 3)
    }

    func test_list_sortsBySentAtAscending() async {
        let groupID = "cc".repeated(32)
        let older = makeMessage(
            groupID: groupID,
            body: "older",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newer = makeMessage(
            groupID: groupID,
            body: "newer",
            sentAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        // Insert out of order — sort must come from the store.
        _ = await store.insertOrUpdate(newer)
        _ = await store.insertOrUpdate(older)

        let listed = await store.list(groupID: groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed.map(\.body), ["older", "newer"])
    }

    func test_list_unknownGroupID_returnsEmpty() async {
        let listed = await store.list(
            groupID: "ff".repeated(32),
            ownerIDString: kOwner.rawValue.uuidString
        )
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - updateStatus

    func test_updateStatus_flipsOnlyStatusColumn() async {
        let msg = makeMessage(body: "in flight", status: .pending)
        _ = await store.insertOrUpdate(msg)

        await store.updateStatus(
            id: msg.id, ownerIDString: kOwner.rawValue.uuidString,
            status: .sent, failureReason: nil
        )

        let listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed[0].status, .sent)
        XCTAssertEqual(listed[0].body, "in flight",
                       "body must survive a status-only update")
    }

    func test_updateStatus_failureReason_roundTripsAndClears() async {
        let msg = makeMessage(body: "doomed", status: .pending)
        _ = await store.insertOrUpdate(msg)

        await store.updateStatus(
            id: msg.id, ownerIDString: kOwner.rawValue.uuidString,
            status: .failed, failureReason: .secureConnectionFailed
        )
        var listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed[0].status, .failed)
        XCTAssertEqual(listed[0].failureReason, .secureConnectionFailed,
                       "the reason must survive the store round-trip")

        // Retry flips back to pending with a nil reason — the stale
        // explanation must clear.
        await store.updateStatus(
            id: msg.id, ownerIDString: kOwner.rawValue.uuidString,
            status: .pending, failureReason: nil
        )
        listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertNil(listed[0].failureReason)
    }

    func test_updateStatus_unknownID_isNoOp() async {
        await store.updateStatus(
            id: UUID(), ownerIDString: kOwner.rawValue.uuidString,
            status: .sent, failureReason: nil
        )
        // No throw, no row, no surprise.
        let listed = await store.list(groupID: "aa".repeated(32), ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - delete

    func test_delete_removesRow() async {
        let msg = makeMessage()
        _ = await store.insertOrUpdate(msg)
        await store.delete(id: msg.id, ownerIDString: kOwner.rawValue.uuidString)
        let listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertTrue(listed.isEmpty)
    }

    func test_delete_isScopedToOwner() async {
        let groupID = "aa".repeated(32)
        let sharedID = UUID()
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        _ = await store.insertOrUpdate(makeMessage(id: sharedID, groupID: groupID, ownerIdentityID: ownerA))
        _ = await store.insertOrUpdate(makeMessage(id: sharedID, groupID: groupID, ownerIdentityID: ownerB))

        await store.delete(id: sharedID, ownerIDString: ownerA.rawValue.uuidString)

        let aRows = await store.list(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)
        let bRows = await store.list(groupID: groupID, ownerIDString: ownerB.rawValue.uuidString)
        XCTAssertTrue(aRows.isEmpty)
        XCTAssertEqual(bRows.count, 1, "deleting one identity's copy leaves the other's row")
    }

    func test_deleteGroup_removesAllMessagesForGroup() async {
        let groupA = "aa".repeated(32)
        let groupB = "bb".repeated(32)
        _ = await store.insertOrUpdate(makeMessage(groupID: groupA, body: "a1"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupA, body: "a2"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupB, body: "b1"))

        await store.deleteGroup(groupID: groupA, ownerIDString: kOwner.rawValue.uuidString)
        let remainingA = await store.list(groupID: groupA, ownerIDString: kOwner.rawValue.uuidString)
        let remainingB = await store.list(groupID: groupB, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertTrue(remainingA.isEmpty)
        XCTAssertEqual(remainingB.count, 1)
    }

    func test_deleteGroup_isScopedToOwner() async {
        let groupID = "aa".repeated(32)
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        _ = await store.insertOrUpdate(makeMessage(groupID: groupID, ownerIdentityID: ownerA, body: "a"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupID, ownerIdentityID: ownerB, body: "b"))

        await store.deleteGroup(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)

        let aRows = await store.list(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)
        let bRows = await store.list(groupID: groupID, ownerIDString: ownerB.rawValue.uuidString)
        XCTAssertTrue(aRows.isEmpty)
        XCTAssertEqual(bRows.map(\.body), ["b"],
                       "deleting one identity's thread leaves the other's copy of the group")
    }

    func test_insertOrUpdate_replayWithoutProof_preservesStoredEvidence() async {
        let id = UUID()
        let original = makeMessage(
            id: id,
            body: "prohibited content",
            direction: .incoming,
            status: .received,
            moderationAuthenticityProof: "c2lnbmF0dXJl"
        )
        _ = await store.insertOrUpdate(original)

        // An abuser re-sends the same messageID with the proof omitted,
        // a laundered body, a shifted timestamp, AND a bolted-on
        // attachment (media messages aren't reportable, so a surviving
        // attachment would remove Report from the menu even with the
        // pair intact). Incoming rows are immutable once received, so
        // nothing about the stored row may change.
        let replay = makeMessage(
            id: id,
            body: "innocent content",
            sentAt: original.sentAt.addingTimeInterval(3600),
            direction: .incoming,
            status: .received,
            moderationAuthenticityProof: nil,
            imageAttachment: ChatImageAttachment(
                sha256: "cd".repeated(32), mimeType: "image/jpeg",
                byteSize: 1, width: 1, height: 1,
                encKey: Data(repeating: 7, count: 32),
                blurhash: "LEHV6nWB2yk8", server: "https://blossom.test"
            )
        )
        let outcome = await store.insertOrUpdate(replay)
        XCTAssertEqual(outcome, .updated)

        let listed = await store.list(
            groupID: original.groupID, ownerIDString: kOwner.rawValue.uuidString
        )
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].body, "prohibited content")
        XCTAssertEqual(listed[0].sentAt, original.sentAt)
        XCTAssertEqual(listed[0].senderBlsPubkeyHex, original.senderBlsPubkeyHex)
        XCTAssertEqual(listed[0].moderationAuthenticityProof, "c2lnbmF0dXJl")
        XCTAssertNil(listed[0].imageAttachment,
                     "a proof-less replay must not bolt on an attachment")
    }

    func test_insertOrUpdate_incomingReplayWithFreshProof_neverMutatesSignedTuple() async {
        // The strongest laundering attempt: same messageID, laundered
        // body, shifted timestamp, and a *fresh* proof over the new
        // preimage (the sender holds the signing key, so it verifies).
        // An incoming row is immutable once received — a legitimate
        // replay is byte-identical, so divergence is hostile.
        let id = UUID()
        let original = makeMessage(
            id: id,
            body: "prohibited content",
            direction: .incoming,
            status: .received,
            moderationAuthenticityProof: "c2lnbmF0dXJl"
        )
        _ = await store.insertOrUpdate(original)

        let replay = makeMessage(
            id: id,
            body: "innocent content",
            sentAt: original.sentAt.addingTimeInterval(-3600),
            direction: .incoming,
            status: .received,
            moderationAuthenticityProof: "ZnJlc2gtdmFsaWQtcHJvb2Y="
        )
        let outcome = await store.insertOrUpdate(replay)
        XCTAssertEqual(outcome, .updated)

        let listed = await store.list(
            groupID: original.groupID, ownerIDString: kOwner.rawValue.uuidString
        )
        XCTAssertEqual(listed[0].body, "prohibited content")
        XCTAssertEqual(listed[0].sentAt, original.sentAt)
        XCTAssertEqual(listed[0].moderationAuthenticityProof, "c2lnbmF0dXJl")
    }

    func test_insertOrUpdate_incomingEcho_neverRewritesOutgoingRow() async {
        // A group member replays the recipient's own messageID as an
        // incoming payload. Cross-direction overwrites are refused —
        // the sender's own row must survive untouched.
        let id = UUID()
        let mine = makeMessage(
            id: id,
            body: "my message",
            direction: .outgoing,
            status: .sent,
            moderationAuthenticityProof: "bXktcHJvb2Y="
        )
        _ = await store.insertOrUpdate(mine)

        let echo = makeMessage(
            id: id,
            body: "forged echo",
            direction: .incoming,
            status: .received
        )
        _ = await store.insertOrUpdate(echo)

        let listed = await store.list(
            groupID: mine.groupID, ownerIDString: kOwner.rawValue.uuidString
        )
        XCTAssertEqual(listed[0].body, "my message")
        XCTAssertEqual(listed[0].direction, .outgoing)
        XCTAssertEqual(listed[0].moderationAuthenticityProof, "bXktcHJvb2Y=")
    }

    func test_insertOrUpdate_outgoingRow_stillAcceptsOverwrites() async {
        // Outgoing rows keep the full update path — the pending → sent
        // flip and retry re-inserts depend on it.
        let id = UUID()
        _ = await store.insertOrUpdate(makeMessage(
            id: id, body: "draft", status: .pending
        ))
        _ = await store.insertOrUpdate(makeMessage(
            id: id, body: "draft", status: .sent
        ))

        let listed = await store.list(
            groupID: "aa".repeated(32), ownerIDString: kOwner.rawValue.uuidString
        )
        XCTAssertEqual(listed[0].status, .sent)
    }

    func test_deleteOwner_removesAllMessagesForIdentity() async {
        let aliceID = IdentityID()
        let bobID = IdentityID()
        let groupA = "aa".repeated(32)
        _ = await store.insertOrUpdate(
            makeMessage(groupID: groupA, ownerIdentityID: aliceID, body: "alice")
        )
        _ = await store.insertOrUpdate(
            makeMessage(groupID: groupA, ownerIdentityID: bobID, body: "bob")
        )

        await store.deleteOwner(aliceID.rawValue.uuidString)

        let alice = await store.list(groupID: groupA, ownerIDString: aliceID.rawValue.uuidString)
        let bob = await store.list(groupID: groupA, ownerIDString: bobID.rawValue.uuidString)
        XCTAssertTrue(alice.isEmpty)
        XCTAssertEqual(bob.map(\.body), ["bob"])
    }

    // MARK: - Helpers

    private func makeMessage(
        id: UUID = UUID(),
        groupID: String = "aa".repeated(32),
        ownerIdentityID: IdentityID = kOwner,
        senderHex: String = "11".repeated(48),
        body: String = "hi",
        sentAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        direction: MessageDirection = .outgoing,
        status: MessageStatus = .sent,
        replyToMessageID: UUID? = nil,
        moderationAuthenticityProof: String? = nil,
        imageAttachment: ChatImageAttachment? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            groupID: groupID,
            ownerIdentityID: ownerIdentityID,
            senderBlsPubkeyHex: senderHex,
            body: body,
            sentAt: sentAt,
            direction: direction,
            status: status,
            replyToMessageID: replyToMessageID,
            groupType: .tyranny,
            moderationAuthenticityProof: moderationAuthenticityProof,
            imageAttachment: imageAttachment
        )
    }
}

/// Shared default owner for the single-identity tests above. File-scope
/// so `makeMessage`'s default argument can reference it.
private let kOwner = IdentityID()

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
