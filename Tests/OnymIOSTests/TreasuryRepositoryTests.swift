import CryptoKit
import XCTest
@testable import OnymIOS
import OnymIdentity
import OnymStellar
import OnymTreasury

/// The repository's behaviour around signatures, standing and identity
/// scoping, over an in-memory store and a canned Horizon.
final class TreasuryRepositoryTests: XCTestCase {

    private let owner = IdentityID(UUID())
    private let other = IdentityID(UUID())
    private let groupID = String(repeating: "cd", count: 32)
    private let treasuryAccount = TreasuryTestKeys.account(30)
    private let signerKey = TreasuryTestKeys.key(31)
    private var signer: StellarAccountID { TreasuryTestKeys.account(31) }

    // MARK: - Signatures

    func test_aValidSignature_isAttachedAndCounts() async throws {
        let (repository, store) = await makeRepository()
        let proposal = try await seedProposal(store: store)

        let hash = proposal.envelope.transaction.hash(network: .testnet)
        let signature = try signerKey.signature(for: hash)

        let added = await repository.addSignature(
            signature,
            from: signer,
            toProposal: proposal.id
        )
        XCTAssertTrue(added)

        let fetched = await repository.proposal(id: proposal.id)
        let stored = try XCTUnwrap(fetched)
        XCTAssertTrue(stored.proposal.envelope.hasSignature(from: signer, network: .testnet))
    }

    /// A signature made over a different transaction is refused, so a
    /// peer cannot move a signature from one proposal onto another.
    func test_aSignatureOverAnotherTransaction_isRefused() async throws {
        let (repository, store) = await makeRepository()
        let proposal = try await seedProposal(store: store)

        let otherTransaction = try StellarTransaction(
            sourceAccount: treasuryAccount,
            fee: 100,
            sequenceNumber: 99,
            timeBounds: nil,
            operations: [payment()]
        )
        let signature = try signerKey.signature(
            for: otherTransaction.hash(network: .testnet)
        )

        let added = await repository.addSignature(
            signature,
            from: signer,
            toProposal: proposal.id
        )
        XCTAssertFalse(added)
        let fetched = await repository.proposal(id: proposal.id)
        let stored = try XCTUnwrap(fetched)
        XCTAssertTrue(stored.proposal.envelope.signatures.isEmpty)
    }

    /// A signature that verifies also settles the open question about an
    /// externally-held account: whoever declared it can evidently sign
    /// with it.
    func test_aValidSignature_provesAnExternalDeclaration() async throws {
        let (repository, store) = await makeRepository()
        let proposal = try await seedProposal(store: store, declarationSource: .external)

        var snapshot = await repository.snapshot(groupID: groupID)
        XCTAssertEqual(snapshot.declarations.first?.provenAt, nil)

        let signature = try signerKey.signature(
            for: proposal.envelope.transaction.hash(network: .testnet)
        )
        await repository.addSignature(signature, from: signer, toProposal: proposal.id)

        snapshot = await repository.snapshot(groupID: groupID)
        XCTAssertNotNil(snapshot.declarations.first?.provenAt)
    }

    // MARK: - Standing

    /// Until a live account read succeeds there is no honest answer, so
    /// the snapshot returns nil rather than deciding from a cached
    /// signer set. "Ready" is the one answer that must never be wrong.
    func test_withoutALiveAccountRead_standingIsUnknownRatherThanGuessed() async throws {
        let (repository, store) = await makeRepository(seedHorizon: false)
        let proposal = try await seedProposal(store: store)
        let snapshot = await repository.snapshot(groupID: groupID)
        let stored = try XCTUnwrap(snapshot.proposals.first)
        XCTAssertNil(snapshot.standing(of: stored, now: Date()))
    }

    func test_afterARefresh_standingIsDerivedFromTheChain() async throws {
        let (repository, store) = await makeRepository()
        let proposal = try await seedProposal(store: store)
        await repository.refresh(groupID: groupID)

        let snapshot = await repository.snapshot(groupID: groupID)
        let stored = try XCTUnwrap(snapshot.proposals.first)
        XCTAssertEqual(
            snapshot.standing(of: stored, now: Date()),
            .collecting(weight: 0, required: 2)
        )
        _ = proposal
    }

    func test_aRejectedProposal_reportsItsRefusalRatherThanProgress() async throws {
        let (repository, store) = await makeRepository()
        let proposal = try await seedProposal(store: store, rejection: .wrongNetwork)
        let snapshot = await repository.snapshot(groupID: groupID)
        let stored = try XCTUnwrap(snapshot.proposals.first)
        XCTAssertEqual(
            snapshot.standing(of: stored, now: Date()),
            .rejected(reason: .wrongNetwork)
        )
        _ = proposal
    }

    // MARK: - Identity scoping

    /// Rows belong to one identity. Two identities on one device that
    /// are both in a group each keep their own treasury state, and
    /// removing one must not touch the other's.
    func test_removingAnIdentity_leavesAnotherIdentitysRowsAlone() async throws {
        let store = InMemoryTreasuryStore()
        let horizon = FakeHorizonClient()
        let repository = TreasuryRepository(store: store, horizon: { _ in horizon })

        for identity in [owner, other] {
            await store.upsert(Treasury(
                account: treasuryAccount,
                groupID: groupID,
                ownerIdentityID: identity,
                network: .testnet,
                creationTxHash: "hash",
                createdAt: Date()
            ))
        }

        await repository.removeForOwner(owner)

        await repository.setCurrentIdentity(owner)
        let mine = await repository.snapshot(groupID: groupID).treasury
        XCTAssertNil(mine)
        await repository.setCurrentIdentity(other)
        let theirs = await repository.snapshot(groupID: groupID).treasury
        XCTAssertNotNil(theirs)
    }

    /// A returned envelope carries no group id, so attribution is by
    /// verification: offered to every open proposal, accepted only by
    /// the one it was actually signed over.
    func test_openProposalsAcrossGroups_areOfferedTheirSigners() async throws {
        let (repository, store) = await makeRepository()
        let proposal = try await seedProposal(store: store)

        let open = await repository.openProposalsWithSigners()
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.0.proposal.id, proposal.id)
        XCTAssertEqual(open.first?.1, [signer])
    }

    func test_aSubmittedProposal_isNoLongerOpen() async throws {
        let (repository, store) = await makeRepository()
        let proposal = try await seedProposal(store: store)
        await repository.markSubmitted(proposalID: proposal.id, txHash: "abc")
        let open = await repository.openProposalsWithSigners()
        XCTAssertTrue(open.isEmpty)
    }

    // MARK: - Helpers

    private func payment() -> StellarOperation {
        StellarOperation(body: .payment(
            destination: TreasuryTestKeys.account(32),
            asset: .native,
            amount: StellarAmount(stroops: 10)
        ))
    }

    private func makeRepository(
        seedHorizon: Bool = true
    ) async -> (TreasuryRepository, InMemoryTreasuryStore) {
        let store = InMemoryTreasuryStore()
        let horizon = FakeHorizonClient()
        if seedHorizon {
            await horizon.setAccount(HorizonAccount(
                accountID: treasuryAccount,
                sequenceNumber: 1,
                balances: [],
                signers: [StellarSigner(key: signer, weight: 1)],
                thresholds: HorizonThresholds(low: 1, medium: 2, high: 2)
            ))
        }
        let repository = TreasuryRepository(store: store, horizon: { _ in horizon })
        await repository.setCurrentIdentity(owner)
        return (repository, store)
    }

    private func seedProposal(
        store: InMemoryTreasuryStore,
        declarationSource: TreasurySignerSource = .onym,
        rejection: TreasuryRejection? = nil
    ) async throws -> TreasuryProposal {
        await store.upsert(Treasury(
            account: treasuryAccount,
            groupID: groupID,
            ownerIdentityID: owner,
            network: .testnet,
            creationTxHash: "hash",
            createdAt: Date()
        ))
        await store.upsert(TreasurySignerDeclarationRecord(
            groupID: groupID,
            ownerIdentityID: owner,
            memberBlsPubkeyHex: "aa",
            account: signer,
            source: declarationSource,
            signature: Data(repeating: 1, count: 64),
            declarerSendingPublicKey: Data(repeating: 2, count: 32),
            declaredAt: Date()
        ))
        let transaction = try StellarTransaction(
            sourceAccount: treasuryAccount,
            fee: 100,
            sequenceNumber: 2,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 4_000_000_000),
            operations: [payment()]
        )
        let proposal = TreasuryProposal(
            id: UUID(),
            groupID: groupID,
            ownerIdentityID: owner,
            proposerBlsPubkeyHex: "aa",
            treasuryAccount: treasuryAccount,
            network: .testnet,
            kind: .payment,
            envelope: TransactionEnvelope(transaction: transaction),
            createdAt: Date()
        )
        await store.upsert(StoredProposal(proposal: proposal, rejection: rejection))
        return proposal
    }
}
