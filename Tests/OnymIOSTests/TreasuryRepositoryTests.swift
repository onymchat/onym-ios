import CryptoKit
import XCTest
@testable import OnymIOS
import OnymGroup
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
    }

    /// `tx_bad_seq` means somebody else's transaction won the race
    /// between the readiness check and the submit. It needs a different
    /// answer from the user than a generic failure — "this can never
    /// work, propose again" rather than "try again" — and that mapping
    /// had no test.
    func test_aLostSequenceRace_readsAsSupersededRatherThanAFailure() async throws {
        let store = InMemoryTreasuryStore()
        let horizon = FakeHorizonClient()
        await horizon.setAccount(HorizonAccount(
            accountID: treasuryAccount,
            sequenceNumber: 1,
            balances: [],
            signers: [StellarSigner(key: signer, weight: 1)],
            thresholds: HorizonThresholds(low: 1, medium: 1, high: 1)
        ))
        await horizon.setSubmitError(
            .submissionFailed(resultCodes: ["tx_bad_seq"], body: "")
        )
        let repository = TreasuryRepository(store: store, horizon: { _ in horizon })
        await repository.setCurrentIdentity(owner)
        let proposal = try await seedProposal(store: store)

        // Enough weight, so it gets as far as submitting.
        let signature = try signerKey.signature(
            for: proposal.envelope.transaction.hash(network: .testnet)
        )
        await repository.addSignature(signature, from: signer, toProposal: proposal.id)

        let interactor = TreasurySigningInteractor(
            treasury: repository,
            identity: IdentityRepository(
                keychain: IdentityKeychainStore(testNamespace: "seq-\(UUID().uuidString)"),
                selectionStore: .inMemory()
            ),
            broadcaster: TreasuryBroadcaster(
                identity: IdentityRepository(
                    keychain: IdentityKeychainStore(
                        testNamespace: "seq2-\(UUID().uuidString)"
                    ),
                    selectionStore: .inMemory()
                ),
                inboxTransport: FakeInboxTransport(),
                groups: GroupRepository(store: SwiftDataGroupStore.inMemory()),
                treasury: repository
            ),
            horizon: { _ in horizon }
        )
        let outcome = await interactor.submit(proposalID: proposal.id)
        XCTAssertEqual(outcome, .superseded)
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
    func test_openProposalsAcrossGroups_areOfferedTheirOwnSigners() async throws {
        let (repository, store) = await makeRepository()
        let mine = try await seedProposal(store: store)
        // A second group, with a different declared signer. The name of
        // this test promised cross-group attribution and the first
        // version seeded only one group.
        let otherGroup = String(repeating: "ef", count: 32)
        let otherSigner = TreasuryTestKeys.account(33)
        let theirs = try await seedProposal(
            store: store,
            groupID: otherGroup,
            signer: otherSigner,
            amount: 777
        )

        let open = await repository.openProposalsWithSigners()
        XCTAssertEqual(open.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: open.map { ($0.0.proposal.id, $0.1) })
        XCTAssertEqual(byID[mine.id], [signer])
        XCTAssertEqual(byID[theirs.id], [otherSigner])

        // And a signature over one group's proposal is not adopted into
        // the other's — the property that makes attribution-by-
        // verification safe for a link that names no group.
        let signature = try signerKey.signature(
            for: theirs.envelope.transaction.hash(network: .testnet)
        )
        let wrong = await repository.addSignature(
            signature,
            from: signer,
            toProposal: mine.id
        )
        XCTAssertFalse(wrong, "a signature over another proposal was adopted")
    }

    func test_aSubmittedProposal_isNoLongerOpen() async throws {
        let (repository, store) = await makeRepository()
        let proposal = try await seedProposal(store: store)
        await repository.markSubmitted(proposalID: proposal.id, txHash: "abc")
        let open = await repository.openProposalsWithSigners()
        XCTAssertTrue(open.isEmpty)
    }

    // MARK: - Helpers

    /// `amount` varies per caller so two groups' proposals are
    /// genuinely different transactions. Seeding both with identical
    /// operations gave them one hash, and a signature over either
    /// verified against both — which made the cross-group test pass for
    /// the wrong reason.
    private func payment(amount: Int64 = 10) -> StellarOperation {
        StellarOperation(body: .payment(
            destination: TreasuryTestKeys.account(32),
            asset: .native,
            amount: StellarAmount(stroops: amount)
        ))
    }

    // MARK: - Somebody else pressed submit

    /// Alice proposes, Bob signs, Bob submits. Alice's copy must say it
    /// went through — not "didn't go through", and not with a Submit
    /// button still on it.
    ///
    /// Only the device that submits writes `submittedTxHash`. Every
    /// other device sees the account's sequence move past the proposal,
    /// and the sequence alone cannot tell "somebody else's transaction
    /// took the slot" from "this transaction took the slot". The
    /// proposal's own hash is fixed before it is signed, so the ledger
    /// can be asked which of the two happened.
    func test_aProposalSubmittedByAnotherDevice_readsAsSubmitted() async throws {
        let store = InMemoryTreasuryStore()
        let horizon = FakeHorizonClient()
        let repository = TreasuryRepository(store: store, horizon: { _ in horizon })
        await repository.setCurrentIdentity(owner)
        let proposal = try await seedProposal(store: store)
        let hash = proposal.envelope.transaction.hash(network: .testnet).hexString

        // The ledger after Bob's submission: the sequence has moved
        // past the proposal, and the proposal's own transaction is in
        // the history.
        await horizon.setAccount(HorizonAccount(
            accountID: treasuryAccount,
            sequenceNumber: proposal.sequenceNumber,
            balances: [],
            signers: [StellarSigner(key: signer, weight: 1)],
            thresholds: HorizonThresholds(low: 1, medium: 1, high: 1)
        ))
        await horizon.setTransactions([
            HorizonTransaction(
                hash: hash,
                ledgerCloseTime: Date(),
                sourceAccount: treasuryAccount,
                successful: true,
                feeCharged: StellarAmount(stroops: 100),
                envelopeXDR: proposal.envelope.base64XDR
            ),
        ])

        // Before: the only thing the sequence can say.
        var snapshot = await repository.snapshot(groupID: groupID)
        var stored = try XCTUnwrap(snapshot.proposals.first)
        await repository.refresh(groupID: groupID)
        snapshot = await repository.snapshot(groupID: groupID)
        stored = try XCTUnwrap(snapshot.proposals.first)
        XCTAssertEqual(snapshot.standing(of: stored, now: Date()), .superseded)

        // After asking the ledger which transaction it was.
        let reconciled = await repository.reconcileSubmittedProposals(groupID: groupID)
        XCTAssertEqual(reconciled, 1)
        snapshot = await repository.snapshot(groupID: groupID)
        stored = try XCTUnwrap(snapshot.proposals.first)
        XCTAssertEqual(snapshot.standing(of: stored, now: Date()), .submitted(txHash: hash))
        XCTAssertFalse(
            snapshot.standing(of: stored, now: Date())?.isActionable ?? true,
            "a transaction that already applied must not still offer Submit"
        )
    }

    /// And the case the old behaviour was right about: the slot really
    /// was taken by something else. The proposal's hash is not in the
    /// history, so superseded stands.
    func test_aProposalOvertakenBySomethingElse_staysSuperseded() async throws {
        let store = InMemoryTreasuryStore()
        let horizon = FakeHorizonClient()
        let repository = TreasuryRepository(store: store, horizon: { _ in horizon })
        await repository.setCurrentIdentity(owner)
        let proposal = try await seedProposal(store: store)

        await horizon.setAccount(HorizonAccount(
            accountID: treasuryAccount,
            sequenceNumber: proposal.sequenceNumber,
            balances: [],
            signers: [StellarSigner(key: signer, weight: 1)],
            thresholds: HorizonThresholds(low: 1, medium: 1, high: 1)
        ))
        await horizon.setTransactions([
            HorizonTransaction(
                hash: "somebody else's transaction",
                ledgerCloseTime: Date(),
                sourceAccount: treasuryAccount,
                successful: true,
                feeCharged: StellarAmount(stroops: 100),
                envelopeXDR: proposal.envelope.base64XDR
            ),
        ])

        let reconciled = await repository.reconcileSubmittedProposals(groupID: groupID)
        XCTAssertEqual(reconciled, 0)
        await repository.refresh(groupID: groupID)
        let snapshot = await repository.snapshot(groupID: groupID)
        let stored = try XCTUnwrap(snapshot.proposals.first)
        XCTAssertEqual(snapshot.standing(of: stored, now: Date()), .superseded)
    }

    /// A transaction the network refused does not count as sent, even
    /// though its hash is in the account's history.
    func test_aFailedTransactionInTheHistory_doesNotCountAsSubmitted() async throws {
        let store = InMemoryTreasuryStore()
        let horizon = FakeHorizonClient()
        let repository = TreasuryRepository(store: store, horizon: { _ in horizon })
        await repository.setCurrentIdentity(owner)
        let proposal = try await seedProposal(store: store)
        let hash = proposal.envelope.transaction.hash(network: .testnet).hexString

        await horizon.setAccount(HorizonAccount(
            accountID: treasuryAccount,
            sequenceNumber: proposal.sequenceNumber,
            balances: [],
            signers: [StellarSigner(key: signer, weight: 1)],
            thresholds: HorizonThresholds(low: 1, medium: 1, high: 1)
        ))
        await horizon.setTransactions([
            HorizonTransaction(
                hash: hash,
                ledgerCloseTime: Date(),
                sourceAccount: treasuryAccount,
                successful: false,
                feeCharged: StellarAmount(stroops: 100),
                envelopeXDR: proposal.envelope.base64XDR
            ),
        ])

        let reconciled = await repository.reconcileSubmittedProposals(groupID: groupID)
        XCTAssertEqual(reconciled, 0)
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
        groupID: String? = nil,
        signer: StellarAccountID? = nil,
        // Explicit rather than derived from the group id: `hashValue`
        // is seeded per process, so a derived amount would make this
        // test's distinctness a coin flip.
        amount: Int64 = 10,
        declarationSource: TreasurySignerSource = .onym,
        rejection: TreasuryRejection? = nil
    ) async throws -> TreasuryProposal {
        let groupID = groupID ?? self.groupID
        let signer = signer ?? self.signer
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
            operations: [payment(amount: amount)]
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
