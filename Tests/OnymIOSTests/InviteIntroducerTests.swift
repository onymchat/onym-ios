import XCTest
@testable import OnymIOS
import OnymIdentity
import OnymGroup

/// Unit tests for `InviteIntroducer` + `IntroKeyStore` contract.
/// Backed by `InMemoryIntroKeyStore` — the Keychain-backed prod
/// impl gets exercised via the round-trip tests in
/// `KeychainIntroKeyStoreTests` (separate suite).
///
/// Mirrors `InviteIntroducerTest.kt` test-for-test.
final class InviteIntroducerTests: XCTestCase {

    private let alice = IdentityID("11111111-1111-1111-1111-111111111111")!
    private let bob = IdentityID("22222222-2222-2222-2222-222222222222")!
    private let sampleGroupId = Data(repeating: 0x42, count: 32)

    /// Everything written before labels existed decodes as
    /// `label == nil`, i.e. indistinguishable from a shared link — and
    /// `listForOwner` is newest-first, so on a create-with-invitees
    /// group the one `currentOrMint` would pick is the LAST INVITEE'S
    /// private offer key. Adopting it hands one person's private link
    /// to everyone; rotating then revokes every legacy invite at once.
    func test_legacyEntries_areNeverAdoptedAsTheSharedLink() async throws {
        let store = InMemoryIntroKeyStore()
        let owner = IdentityID()
        let groupId = Data(repeating: 0x11, count: 32)
        let legacyOffer = IntroKeyEntry(
            introPublicKey: Data(repeating: 0x22, count: 32),
            introPrivateKey: Data(repeating: 0x23, count: 32),
            ownerIdentityID: owner,
            groupId: groupId,
            createdAt: Date(),          // newest, so it would win
            label: nil,
            isLegacy: true
        )
        await store.save(legacyOffer)
        let introducer = InviteIntroducer(store: store)

        let cap = try await introducer.currentOrMint(
            ownerIdentityID: owner, groupId: groupId
        )
        XCTAssertNotEqual(
            cap.introPublicKey, legacyOffer.introPublicKey,
            "a pre-upgrade key must never become the group's public link"
        )

        // And rotating the shared link must leave it alone.
        _ = try await introducer.rotate(ownerIdentityID: owner, groupId: groupId)
        let live = await introducer.liveInvites(ownerIdentityID: owner, groupId: groupId)
        XCTAssertTrue(
            live.contains { $0.introPublicKey == legacyOffer.introPublicKey },
            "rotate must not mass-revoke outstanding pre-upgrade invites"
        )
    }

    func test_mint_producesDistinctKeypairs_acrossInvocations() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        let cap1 = try await introducer.mint(ownerIdentityID: alice, groupId: sampleGroupId)
        let cap2 = try await introducer.mint(ownerIdentityID: alice, groupId: sampleGroupId)

        XCTAssertEqual(cap1.introPublicKey.count, 32)
        XCTAssertEqual(cap2.introPublicKey.count, 32)
        XCTAssertNotEqual(
            cap1.introPublicKey, cap2.introPublicKey,
            "two mints for the same group must produce distinct intro pubkeys"
        )
    }

    func test_mint_persistsKeypair_recoverableViaFind() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        let cap = try await introducer.mint(
            ownerIdentityID: alice,
            groupId: sampleGroupId,
            groupName: "Family"
        )
        let entry = await store.find(introPublicKey: cap.introPublicKey)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.ownerIdentityID, alice)
        XCTAssertEqual(entry?.groupId, sampleGroupId)
        // Private key must round-trip — that's what decrypts requests
        // in PR-3+.
        XCTAssertEqual(entry?.introPrivateKey.count, 32)
        XCTAssertEqual(entry?.introPublicKey, cap.introPublicKey)
    }

    func test_mint_capabilityCarriesGroupName_notTheStore() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        let cap = try await introducer.mint(
            ownerIdentityID: alice,
            groupId: sampleGroupId,
            groupName: "Family"
        )
        XCTAssertEqual(cap.groupName, "Family")
        // The store doesn't persist the name — names live in the
        // ChatGroup row, not in the per-invite store. Keeps the
        // intro store tightly scoped to crypto material.
        let entry = await store.find(introPublicKey: cap.introPublicKey)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.introPublicKey.count, 32)
    }

    func test_listForOwner_returnsOnlyMatchingIdentitysEntries() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        _ = try await introducer.mint(ownerIdentityID: alice, groupId: sampleGroupId)
        _ = try await introducer.mint(ownerIdentityID: alice, groupId: Data(repeating: 0x55, count: 32))
        _ = try await introducer.mint(ownerIdentityID: bob, groupId: sampleGroupId)

        let aliceList = await store.listForOwner(alice)
        let bobList = await store.listForOwner(bob)
        XCTAssertEqual(aliceList.count, 2)
        XCTAssertEqual(bobList.count, 1)
        XCTAssertTrue(aliceList.allSatisfy { $0.ownerIdentityID == alice })
    }

    func test_revoke_removesEntry() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        let cap = try await introducer.mint(ownerIdentityID: alice, groupId: sampleGroupId)
        let beforeRevoke = await store.find(introPublicKey: cap.introPublicKey)
        XCTAssertNotNil(beforeRevoke)

        await store.revoke(introPublicKey: cap.introPublicKey)
        let afterRevoke = await store.find(introPublicKey: cap.introPublicKey)
        XCTAssertNil(afterRevoke)
    }

    func test_deleteForOwner_cascadesAllOwnedEntries_returnsCount() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        _ = try await introducer.mint(ownerIdentityID: alice, groupId: sampleGroupId)
        _ = try await introducer.mint(ownerIdentityID: alice, groupId: Data(repeating: 0x55, count: 32))
        _ = try await introducer.mint(ownerIdentityID: bob, groupId: sampleGroupId)

        let removed = await store.deleteForOwner(alice)
        XCTAssertEqual(removed, 2)
        let aliceAfter = await store.listForOwner(alice)
        let bobAfter = await store.listForOwner(bob)
        XCTAssertEqual(aliceAfter.count, 0)
        XCTAssertEqual(bobAfter.count, 1)
    }

    func test_mint_rejectsWrongSizedGroupId() async {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        do {
            _ = try await introducer.mint(
                ownerIdentityID: alice,
                groupId: Data(repeating: 0, count: 31)
            )
            XCTFail("expected IntroducerError.invalidGroupID")
        } catch IntroducerError.invalidGroupID {
            // expected
        } catch {
            XCTFail("expected IntroducerError.invalidGroupID, got \(error)")
        }
    }

    func test_mint_clockProvider_stampsCreatedAt() async throws {
        let store = InMemoryIntroKeyStore()
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let introducer = InviteIntroducer(store: store, now: { frozen })

        let cap = try await introducer.mint(ownerIdentityID: alice, groupId: sampleGroupId)
        let entry = await store.find(introPublicKey: cap.introPublicKey)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.createdAt, frozen)
    }

    // MARK: - currentOrMint (multi-use links)

    func test_currentOrMint_noLiveKeyForGroup_mintsAndPersistsOne() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        let cap = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        let listed = await store.listForOwner(alice)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.introPublicKey, cap.introPublicKey)
    }

    func test_currentOrMint_twiceForSameGroup_returnsSameKey_persistsOneEntry() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        let first = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let second = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        XCTAssertEqual(first.introPublicKey, second.introPublicKey)
        // The count is what stops this from being "returns the same
        // link but still writes a row".
        let listed = await store.listForOwner(alice)
        XCTAssertEqual(listed.count, 1)
    }

    func test_currentOrMint_differentGroups_doNotShareAKey() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)
        let other = Data(repeating: 0x5A, count: 32)

        let g1 = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let g2 = try await introducer.currentOrMint(ownerIdentityID: alice, groupId: other)

        XCTAssertNotEqual(g1.introPublicKey, g2.introPublicKey)
        let listed = await store.listForOwner(alice)
        XCTAssertEqual(listed.count, 2)
    }

    func test_currentOrMint_neverExpires_soAnAncientKeyIsStillReused() async throws {
        let store = InMemoryIntroKeyStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let early = InviteIntroducer(store: store, now: { t0 })
        // A year later. Invite links have no TTL — only `rotate` or
        // `revoke` retires one.
        let muchLater = InviteIntroducer(
            store: store,
            now: { t0.addingTimeInterval(365 * 24 * 60 * 60) }
        )

        let first = try await early.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let second = try await muchLater.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        XCTAssertEqual(first.introPublicKey, second.introPublicKey)
        let listed = await store.listForOwner(alice)
        XCTAssertEqual(listed.count, 1)
    }

    // MARK: - rotate / revoke

    func test_rotate_mintsAFreshKey_andRetiresTheOldOne() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        let old = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let new = try await introducer.rotate(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        XCTAssertNotEqual(old.introPublicKey, new.introPublicKey)
        let foundOld = await store.find(introPublicKey: old.introPublicKey)
        XCTAssertNil(foundOld, "the superseded link must stop decrypting requests")
        let foundNew = await store.find(introPublicKey: new.introPublicKey)
        XCTAssertNotNil(foundNew)
        let listed = await store.listForOwner(alice)
        XCTAssertEqual(listed.count, 1, "rotate must not leave the old slot behind")
    }

    func test_rotate_thenCurrentOrMint_returnsTheRotatedKey() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        _ = try await introducer.currentOrMint(ownerIdentityID: alice, groupId: sampleGroupId)
        let rotated = try await introducer.rotate(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let resolved = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        XCTAssertEqual(rotated.introPublicKey, resolved.introPublicKey)
    }

    func test_rotate_leavesOtherGroupsAlone() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)
        let other = Data(repeating: 0x5A, count: 32)

        let untouched = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: other
        )
        _ = try await introducer.currentOrMint(ownerIdentityID: alice, groupId: sampleGroupId)
        _ = try await introducer.rotate(ownerIdentityID: alice, groupId: sampleGroupId)

        let foundUntouched = await store.find(introPublicKey: untouched.introPublicKey)
        XCTAssertNotNil(foundUntouched)
    }

    func test_rotate_doesNotRetireLabelledOfferKeys() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        // Per-invitee offers are revoked one at a time from the invite
        // list; rotating the shared link must not sweep them away.
        let offer = try await introducer.mint(
            ownerIdentityID: alice, groupId: sampleGroupId, label: "aabbccdd"
        )
        _ = try await introducer.currentOrMint(ownerIdentityID: alice, groupId: sampleGroupId)
        _ = try await introducer.rotate(ownerIdentityID: alice, groupId: sampleGroupId)

        let foundOffer = await store.find(introPublicKey: offer.introPublicKey)
        XCTAssertNotNil(foundOffer)
    }

    func test_currentOrMint_ignoresLabelledOfferKeys() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        // Create-with-invitees leaves an offer key as the newest entry;
        // handing it out would collapse the 1:1 mapping.
        let offer = try await introducer.mint(
            ownerIdentityID: alice, groupId: sampleGroupId, label: "aabbccdd"
        )
        let shared = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        XCTAssertNotEqual(offer.introPublicKey, shared.introPublicKey)
    }

    func test_liveInvites_listsEveryKeyForTheGroup() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)
        let other = Data(repeating: 0x5A, count: 32)

        let shared = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let offer = try await introducer.mint(
            ownerIdentityID: alice, groupId: sampleGroupId, label: "aabbccdd"
        )
        _ = try await introducer.currentOrMint(ownerIdentityID: alice, groupId: other)

        let live = await introducer.liveInvites(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        XCTAssertEqual(Set(live.map(\.introPublicKey)),
                       Set([shared.introPublicKey, offer.introPublicKey]))
        XCTAssertEqual(live.first(where: { $0.label == "aabbccdd" })?.introPublicKey,
                       offer.introPublicKey)
    }

    func test_currentOrMint_doesNotReuseAnotherIdentitysLiveKey() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        // The pump only subscribes the active identity's tags, so this
        // would hand out a link nobody is listening on.
        let bobCap = try await introducer.currentOrMint(
            ownerIdentityID: bob, groupId: sampleGroupId
        )
        let aliceCap = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        XCTAssertNotEqual(bobCap.introPublicKey, aliceCap.introPublicKey)
        let aliceKeys = await store.listForOwner(alice)
        let bobKeys = await store.listForOwner(bob)
        XCTAssertEqual(aliceKeys.count, 1)
        XCTAssertEqual(bobKeys.count, 1)
    }

    func test_currentOrMint_rejectsWrongSizedGroupId_withoutTouchingTheStore() async {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        do {
            _ = try await introducer.currentOrMint(
                ownerIdentityID: alice,
                groupId: Data(repeating: 0x01, count: 16)
            )
            XCTFail("expected IntroducerError.invalidGroupID")
        } catch IntroducerError.invalidGroupID {
            // expected
        } catch {
            XCTFail("expected IntroducerError.invalidGroupID, got \(error)")
        }

        let listed = await store.listForOwner(alice)
        XCTAssertTrue(listed.isEmpty)
    }

    func test_mint_alwaysMintsFresh_evenWhenALiveKeyExists() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        // Locks the two-entry-point split; collapsing them would break
        // the offers' 1:1 mapping.
        let shared = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let fresh = try await introducer.mint(ownerIdentityID: alice, groupId: sampleGroupId)

        XCTAssertNotEqual(shared.introPublicKey, fresh.introPublicKey)
        let listed = await store.listForOwner(alice)
        XCTAssertEqual(listed.count, 2)
    }

    // MARK: - concurrency

    func test_currentOrMint_concurrentCalls_produceExactlyOneKey() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        // `.onAppear` fires more than once per entry; the store read is
        // an await, so unserialized this mints twice.
        async let a = introducer.currentOrMint(ownerIdentityID: alice, groupId: sampleGroupId)
        async let b = introducer.currentOrMint(ownerIdentityID: alice, groupId: sampleGroupId)
        let (first, second) = try await (a, b)

        XCTAssertEqual(first.introPublicKey, second.introPublicKey)
        let listed = await store.listForOwner(alice)
        XCTAssertEqual(listed.count, 1, "a second shared key would be unrevokable")
    }

    func test_rotate_concurrentWithCurrentOrMint_leavesOneSharedKey() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)
        _ = try await introducer.currentOrMint(ownerIdentityID: alice, groupId: sampleGroupId)

        async let rotated = introducer.rotate(ownerIdentityID: alice, groupId: sampleGroupId)
        async let resolved = introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let (_, handedToCaller) = try await (rotated, resolved)

        // The hazard is the value handed to the concurrent caller, not
        // the end state: unserialized, it can be a link rotate revoked.
        let stillLive = await store.find(introPublicKey: handedToCaller.introPublicKey)
        XCTAssertNotNil(stillLive, "the caller was handed a link that was then revoked")
        let shared = await store.listForOwner(alice).filter { $0.label == nil }
        XCTAssertEqual(shared.count, 1)
    }
}
