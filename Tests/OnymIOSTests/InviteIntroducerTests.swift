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
}
