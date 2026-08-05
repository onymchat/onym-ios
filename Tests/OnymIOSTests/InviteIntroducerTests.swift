import XCTest
@testable import OnymIOS

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

    func test_currentOrMint_expiredKey_mintsAFreshOne() async throws {
        let store = InMemoryIntroKeyStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Two introducers because `now` is injected at init; they share
        // the store, so the second sees the first's (expired) entry.
        let early = InviteIntroducer(store: store, now: { t0 })
        let late = InviteIntroducer(
            store: store,
            now: { t0.addingTimeInterval(IntroKeyEntry.lifetime + 60) }
        )

        let first = try await early.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let second = try await late.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        XCTAssertNotEqual(first.introPublicKey, second.introPublicKey)
    }

    func test_currentOrMint_atExactlyLifetime_isTreatedAsExpired() async throws {
        let store = InMemoryIntroKeyStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let early = InviteIntroducer(store: store, now: { t0 })
        // Pins the strict comparison in `isLive(at:)` against
        // `KeychainIntroKeyStore.loadAll`'s cutoff so the two
        // boundaries can't drift apart.
        let atBoundary = InviteIntroducer(
            store: store,
            now: { t0.addingTimeInterval(IntroKeyEntry.lifetime) }
        )

        let first = try await early.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let second = try await atBoundary.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )

        XCTAssertNotEqual(first.introPublicKey, second.introPublicKey)
    }

    func test_currentOrMint_doesNotReuseAnotherIdentitysLiveKey() async throws {
        let store = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: store)

        // The intro pump only subscribes the *active* identity's tags,
        // so reusing Bob's key for Alice would hand out a link nobody
        // is listening on.
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

        // Locks in the two-entry-point split: collapsing `mint` into
        // `currentOrMint` would silently break the create-time offers'
        // 1:1 request-to-invitee mapping.
        let shared = try await introducer.currentOrMint(
            ownerIdentityID: alice, groupId: sampleGroupId
        )
        let fresh = try await introducer.mint(ownerIdentityID: alice, groupId: sampleGroupId)

        XCTAssertNotEqual(shared.introPublicKey, fresh.introPublicKey)
        let listed = await store.listForOwner(alice)
        XCTAssertEqual(listed.count, 2)
    }
}
