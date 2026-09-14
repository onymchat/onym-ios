import CryptoKit
import Foundation
import XCTest
@testable import OnymIOS
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymStellar
import OnymTreasury

/// The whole treasury round trip, in process.
///
/// Two identities with isolated keychains, a real `GroupRepository`, a
/// real `TreasuryRepository` over an in-memory store, and a Horizon
/// fake that actually *applies* what it is given — so the signer set
/// and sequence number the second half of the test reads are the ones
/// the first half wrote.
///
/// Written as an in-process test rather than a driven UI test on
/// purpose. What is worth proving here is that the pieces agree with
/// each other — payload bytes, verification, signature checking,
/// threshold arithmetic — and that is exactly the part a UI test proves
/// least reliably and most slowly. The screens are thin over these
/// flows.
///
/// Payload bytes are carried between the two sides by hand, standing in
/// for the sealed inbox envelope. That leg is `FakeInboxTransport`'s
/// job and is covered where the broadcaster is.
@MainActor
final class TreasuryE2ETests: XCTestCase {

    private let groupIDHex = String(repeating: "7e", count: 32)
    private var groupIDData: Data { Data(repeating: 0x7e, count: 32) }

    private var adaKeychain: IdentityKeychainStore!
    private var boKeychain: IdentityKeychainStore!
    private var ada: IdentityRepository!
    private var bo: IdentityRepository!

    // Ada founds the group; Bo is a member.
    private static let adaMnemonic =
        "legal winner thank year wave sausage worth useful legal winner thank yellow"
    private static let boMnemonic =
        "letter advice cage absurd amount doctor acoustic avoid letter advice cage above"

    override func setUp() async throws {
        try await super.setUp()
        adaKeychain = IdentityKeychainStore(testNamespace: "treasury-ada-\(UUID().uuidString)")
        boKeychain = IdentityKeychainStore(testNamespace: "treasury-bo-\(UUID().uuidString)")
        ada = IdentityRepository(keychain: adaKeychain, selectionStore: .inMemory())
        bo = IdentityRepository(keychain: boKeychain, selectionStore: .inMemory())
        _ = try await ada.restore(mnemonic: Self.adaMnemonic)
        _ = try await bo.restore(mnemonic: Self.boMnemonic)
    }

    override func tearDown() async throws {
        try? adaKeychain?.wipeAll()
        try? boKeychain?.wipeAll()
        try await super.tearDown()
    }

    /// Declare → create → propose → co-sign → ready → submit.
    func test_twoPeople_fundAndSpendATreasuryTogether() async throws {
        let adaLoaded = await ada.currentIdentity()
        let boLoaded = await bo.currentIdentity()
        let adaSelected = await ada.currentSelectedID()
        let boSelected = await bo.currentSelectedID()
        let adaIdentity = try XCTUnwrap(adaLoaded)
        let boIdentity = try XCTUnwrap(boLoaded)
        let adaOwner = try XCTUnwrap(adaSelected)
        let boOwner = try XCTUnwrap(boSelected)

        let adaSigner = try StellarAccountID(accountID: adaIdentity.treasuryAccountID)
        let boSigner = try StellarAccountID(accountID: boIdentity.treasuryAccountID)

        // The treasury key is deliberately not the identity key: Stellar
        // signs a bare 32-byte hash, and that key already signs
        // mandates and rules agreements.
        XCTAssertNotEqual(adaIdentity.treasuryAccountID, adaIdentity.stellarAccountID)

        let ledger = LedgerHorizon()
        // Ada funds from her own declared account.
        await ledger.create(account: adaSigner, balance: 1_000_000_000)

        let adaSide = try await makeSide(
            identity: ada,
            owner: adaOwner,
            me: adaIdentity,
            peer: boIdentity,
            adminBlsHex: adaIdentity.blsPublicKey.hexString,
            adminEd25519Hex: adaIdentity.stellarPublicKey.hexString,
            ledger: ledger
        )
        let boSide = try await makeSide(
            identity: bo,
            owner: boOwner,
            me: boIdentity,
            peer: adaIdentity,
            adminBlsHex: adaIdentity.blsPublicKey.hexString,
            adminEd25519Hex: adaIdentity.stellarPublicKey.hexString,
            ledger: ledger
        )

        // 1. Both declare which Stellar account speaks for them.
        for (side, identity) in [(adaSide, adaIdentity), (boSide, boIdentity)] {
            let account = try StellarAccountID(accountID: identity.treasuryAccountID)
            await side.repository.record(TreasurySignerDeclarationRecord(
                groupID: groupIDHex,
                ownerIdentityID: side.owner,
                memberBlsPubkeyHex: identity.blsPublicKey.hexString,
                account: account,
                source: .onym,
                signature: try sign(
                    identity: side.identity,
                    account: account,
                    sendingKey: identity.stellarPublicKey
                ),
                declarerSendingPublicKey: identity.stellarPublicKey,
                declaredAt: Date()
            ))
        }
        // Ada also holds Bo's declaration — she needs it to build the
        // signer set.
        await adaSide.repository.record(TreasurySignerDeclarationRecord(
            groupID: groupIDHex,
            ownerIdentityID: adaOwner,
            memberBlsPubkeyHex: boIdentity.blsPublicKey.hexString,
            account: boSigner,
            source: .onym,
            signature: try sign(
                identity: bo,
                account: boSigner,
                sendingKey: boIdentity.stellarPublicKey
            ),
            declarerSendingPublicKey: boIdentity.stellarPublicKey,
            declaredAt: Date()
        ))

        // 2. Ada creates the treasury: one envelope, both signatures.
        let created = await adaSide.creation.create(
            groupIDHex: groupIDHex,
            funder: adaSigner,
            coSigners: [adaSigner, boSigner].map { TreasuryCoSigner(account: $0) },
            thresholds: TreasuryThresholds(low: 1, medium: 2, high: 2),
            spendable: try StellarAmount(decimalString: "100"),
            network: .testnet
        )
        guard case .created(let treasury) = created else {
            return XCTFail("creation failed: \(created)")
        }

        // The account exists, its own key is switched off, and the two
        // co-signers are on it — read back from the ledger, not from
        // what we asked for.
        let onChain = try await ledger.account(treasury.account)
        // `?? 0` would default to the passing value, so the assertion
        // would also hold with the master key absent entirely — which
        // is in fact what Horizon returns for weight 0, meaning the
        // check could never fail either way. Absent or zero, stated as
        // the two acceptable answers rather than folded into one.
        let master = onChain.signers.first { $0.key == treasury.account }
        XCTAssertTrue(
            master == nil || master?.weight == 0,
            "the treasury's own key must be switched off, was \(String(describing: master))"
        )
        let liveSigners: Set<StellarAccountID> = Set(
            onChain.signers.filter { $0.weight > 0 }.map(\.key)
        )
        XCTAssertEqual(liveSigners, Set([adaSigner, boSigner]))
        XCTAssertEqual(onChain.thresholds.medium, 2)

        // 3. Bo learns about the treasury the way a member does.
        await boSide.receiver.apply(
            TreasuryAnchorPayload(
                groupID: groupIDData,
                treasuryAccountID: treasury.account.accountID,
                networkPassphrase: StellarNetwork.testnet.passphrase,
                creationTxHash: treasury.creationTxHash,
                sentAtMillis: 1
            ),
            ownerIdentityID: boOwner,
            senderEd25519PublicKey: adaIdentity.stellarPublicKey
        )
        let boTreasury = await boSide.repository.snapshot(groupID: groupIDHex).treasury
        XCTAssertEqual(boTreasury?.account, treasury.account)

        // 4. Ada proposes a payment. She signs her own proposal.
        //
        // The recipient has to exist: real Horizon answers
        // `op_no_destination` for an unfunded one, and the ledger fake
        // now does too.
        let recipient = TreasuryTestKeys.account(77)
        await ledger.create(account: recipient, balance: 0)
        let proposed = await adaSide.proposing.proposePayment(
            groupID: groupIDHex,
            destination: recipient,
            asset: .native,
            amount: try StellarAmount(decimalString: "5")
        )
        guard case .proposed(let proposal) = proposed else {
            return XCTFail("proposal failed: \(proposed)")
        }
        XCTAssertTrue(proposal.envelope.hasSignature(from: adaSigner, network: .testnet))

        // One signature of the two needed.
        var adaSnapshot = await adaSide.repository.snapshot(groupID: groupIDHex)
        var stored = try XCTUnwrap(adaSnapshot.proposals.first)
        XCTAssertEqual(
            adaSnapshot.standing(of: stored, now: Date()),
            .collecting(weight: 1, required: 2)
        )

        // 5. Bo receives the proposal, and his device decodes it itself.
        await boSide.receiver.apply(
            TreasuryProposalPayload(
                groupID: groupIDData,
                proposalID: proposal.id,
                proposerBlsPubkeyHex: adaIdentity.blsPublicKey.hexString,
                xdr: proposal.envelope.base64XDR,
                networkPassphrase: StellarNetwork.testnet.passphrase,
                sentAtMillis: 2
            ),
            ownerIdentityID: boOwner,
            senderEd25519PublicKey: adaIdentity.stellarPublicKey
        )
        let boFetched = await boSide.repository.proposal(id: proposal.id)
        let boStored = try XCTUnwrap(boFetched)
        XCTAssertNil(boStored.rejection, "Bo refused a genuine proposal")
        // What Bo is shown comes from the bytes, not from Ada.
        let description = TreasuryProposalDescription(boStored.proposal)
        XCTAssertEqual(String(localized: description.title), "Pay 5 XLM")
        XCTAssertNil(description.caveat)
        XCTAssertTrue(description.lines.contains { $0.value == .account(recipient) })

        // 6. Bo signs.
        let boOutcome = await boSide.signing.sign(proposalID: proposal.id)
        XCTAssertEqual(boOutcome, .signed)
        let boSignedFetched = await boSide.repository.proposal(id: proposal.id)
        let boSigned = try XCTUnwrap(boSignedFetched)
        let boSignature = try XCTUnwrap(
            boSigned.proposal.envelope.signatures.last?.signature
        )

        // 7. Ada receives Bo's signature and the proposal is ready.
        await adaSide.receiver.apply(
            TreasurySignaturePayload(
                groupID: groupIDData,
                proposalID: proposal.id,
                signerAccountID: boSigner.accountID,
                signature: boSignature,
                sentAtMillis: 3
            ),
            ownerIdentityID: adaOwner
        )
        await adaSide.repository.refresh(groupID: groupIDHex)
        adaSnapshot = await adaSide.repository.snapshot(groupID: groupIDHex)
        stored = try XCTUnwrap(adaSnapshot.proposals.first)
        XCTAssertEqual(adaSnapshot.standing(of: stored, now: Date()), .ready)

        // 8. Submitting applies it, and the recipient is paid.
        let submitted = await adaSide.signing.submit(proposalID: proposal.id)
        guard case .submitted = submitted else {
            return XCTFail("submit failed: \(submitted)")
        }
        let paid = try await ledger.account(recipient)
        XCTAssertEqual(paid.balances.first?.balance.decimalString, "5")

        // And the proposal that spent the sequence number is done.
        await adaSide.repository.refresh(groupID: groupIDHex)
        adaSnapshot = await adaSide.repository.snapshot(groupID: groupIDHex)
        stored = try XCTUnwrap(adaSnapshot.proposals.first)
        guard case .submitted = adaSnapshot.standing(of: stored, now: Date()) else {
            return XCTFail("expected the proposal to read as submitted")
        }
    }

    /// The claim the ledger fake exists to support: creation applies
    /// whole or not at all, and its operations are in an order the
    /// network will accept.
    ///
    /// Moving the lockdown ahead of the signer installs makes the
    /// treasury's own key weightless before the operations that need it
    /// run — so the fake must refuse it. Previously it applied
    /// `setOptions` from any source without consulting weights, and
    /// this reordering passed every assertion.
    func test_aCreationWithTheLockdownFirst_isRefusedByTheLedger() async throws {
        let loaded = await ada.currentIdentity()
        let adaIdentity = try XCTUnwrap(loaded)
        let adaSigner = try StellarAccountID(accountID: adaIdentity.treasuryAccountID)
        let ledger = LedgerHorizon()
        await ledger.create(account: adaSigner, balance: 1_000_000_000)

        let treasuryKey = try EphemeralTreasuryKey()
        let bounds = StellarTimeBounds(minTime: 0, maxTime: 4_000_000_000)
        // The lockdown first, then the signer install it would forbid.
        let transaction = try StellarTransaction(
            sourceAccount: adaSigner,
            fee: 300,
            sequenceNumber: 2,
            timeBounds: bounds,
            operations: [
                StellarOperation(body: .createAccount(
                    destination: treasuryKey.account,
                    startingBalance: StellarAmount(stroops: 20_000_000)
                )),
                StellarOperation(sourceAccount: treasuryKey.account, body: .setOptions(
                    SetOptionsFields(masterWeight: 0, lowThreshold: 1,
                                     mediumThreshold: 1, highThreshold: 1)
                )),
                StellarOperation(sourceAccount: treasuryKey.account, body: .setOptions(
                    SetOptionsFields(signer: StellarSigner(key: adaSigner, weight: 1))
                )),
            ]
        )
        var envelope = TransactionEnvelope(transaction: transaction)
        try treasuryKey.sign(&envelope, network: .testnet)
        let signature = try await ada.signWithTreasuryKey(
            transaction.hash(network: .testnet)
        )
        try envelope.addSignature(signature, from: adaSigner, network: .testnet)

        do {
            _ = try await ledger.submit(envelope)
            XCTFail("the ledger accepted a creation whose lockdown ran first")
        } catch let error as HorizonError {
            guard case .submissionFailed(let codes, _) = error else {
                return XCTFail("expected an auth failure, got \(error)")
            }
            XCTAssertEqual(codes, ["tx_bad_auth"])
        }
    }

    /// "Applies whole or not at all" — asserted, not just claimed.
    ///
    /// The fake mutated per operation with no rollback, so after the
    /// `tx_bad_auth` above the treasury existed half-configured. That
    /// is the exact property the atomic-creation design rests on, which
    /// makes it the last thing the fake should get wrong.
    func test_aRefusedCreation_leavesNothingBehind() async throws {
        let loaded = await ada.currentIdentity()
        let adaIdentity = try XCTUnwrap(loaded)
        let adaSigner = try StellarAccountID(accountID: adaIdentity.treasuryAccountID)
        let ledger = LedgerHorizon()
        await ledger.create(account: adaSigner, balance: 1_000_000_000)

        let treasuryKey = try EphemeralTreasuryKey()
        let transaction = try StellarTransaction(
            sourceAccount: adaSigner,
            fee: 300,
            sequenceNumber: 2,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 4_000_000_000),
            operations: [
                StellarOperation(body: .createAccount(
                    destination: treasuryKey.account,
                    startingBalance: StellarAmount(stroops: 20_000_000)
                )),
                StellarOperation(sourceAccount: treasuryKey.account, body: .setOptions(
                    SetOptionsFields(masterWeight: 0, lowThreshold: 1,
                                     mediumThreshold: 1, highThreshold: 1)
                )),
                StellarOperation(sourceAccount: treasuryKey.account, body: .setOptions(
                    SetOptionsFields(signer: StellarSigner(key: adaSigner, weight: 1))
                )),
            ]
        )
        var envelope = TransactionEnvelope(transaction: transaction)
        try treasuryKey.sign(&envelope, network: .testnet)
        let signature = try await ada.signWithTreasuryKey(
            transaction.hash(network: .testnet)
        )
        try envelope.addSignature(signature, from: adaSigner, network: .testnet)

        _ = try? await ledger.submit(envelope)

        // The account the first operation would have created must not
        // exist, and the funder must not have been debited.
        do {
            _ = try await ledger.account(treasuryKey.account)
            XCTFail("a refused creation left a half-configured account behind")
        } catch {}
        let funder = try await ledger.account(adaSigner)
        XCTAssertEqual(funder.balances.first?.balance.stroops, 1_000_000_000)
        XCTAssertEqual(funder.sequenceNumber, 1, "a refused transaction consumed a sequence")
    }

    /// And the other half: an under-signed payment is refused by the
    /// ledger, not only by the client-side readiness check.
    func test_anUnderSignedPayment_isRefusedByTheLedger() async throws {
        let loaded = await ada.currentIdentity()
        let adaIdentity = try XCTUnwrap(loaded)
        let adaSigner = try StellarAccountID(accountID: adaIdentity.treasuryAccountID)
        let ledger = LedgerHorizon()
        let treasuryAccount = TreasuryTestKeys.account(70)
        await ledger.create(account: treasuryAccount, balance: 100_000_000)
        await ledger.setControl(
            of: treasuryAccount,
            signers: [adaSigner.accountID: 1, TreasuryTestKeys.account(71).accountID: 1],
            thresholds: HorizonThresholds(low: 1, medium: 2, high: 2)
        )
        let recipient = TreasuryTestKeys.account(72)
        await ledger.create(account: recipient, balance: 0)

        let transaction = try StellarTransaction(
            sourceAccount: treasuryAccount,
            fee: 100,
            sequenceNumber: 2,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 4_000_000_000),
            operations: [
                StellarOperation(body: .payment(
                    destination: recipient,
                    asset: .native,
                    amount: StellarAmount(stroops: 1_000)
                )),
            ]
        )
        var envelope = TransactionEnvelope(transaction: transaction)
        let signature = try await ada.signWithTreasuryKey(
            transaction.hash(network: .testnet)
        )
        try envelope.addSignature(signature, from: adaSigner, network: .testnet)

        // One of the two required signatures.
        do {
            _ = try await ledger.submit(envelope)
            XCTFail("the ledger accepted a payment one signature short")
        } catch let error as HorizonError {
            guard case .submissionFailed(let codes, _) = error else {
                return XCTFail("expected an auth failure, got \(error)")
            }
            XCTAssertEqual(codes, ["tx_bad_auth"])
        }
    }

    // MARK: - The split external path

    /// The whole of it, with the wallet's half played by hand: Onym
    /// builds a funding transaction, "the wallet" signs and submits it,
    /// and Onym then configures the account and anchors it.
    ///
    /// The split exists because SEP-0007 wallets will not submit a
    /// two-source envelope, so the part worth proving is that the
    /// second half — which no wallet touches — actually locks the
    /// account down against a ledger that enforces authorisation.
    func test_externalCreation_isFundedByTheWalletAndLockedDownHere() async throws {
        let world = try await makeExternalWorld()

        let request = try await handOff(world)
        let loadedPending = await world.side.repository.pendingCreation(groupID: groupIDHex)
        let accountID = try XCTUnwrap(loadedPending).treasuryAccount.accountID

        // What a wallet is given: one operation, one source, unsigned.
        let funding = request.envelope.transaction
        XCTAssertEqual(funding.operations.count, 1)
        XCTAssertTrue(request.envelope.signatures.isEmpty)

        // The wallet's half.
        var walletEnvelope = request.envelope
        try walletEnvelope.addSignature(
            try world.funderKey.signature(for: funding.hash(network: .testnet)),
            from: world.funder,
            network: .testnet
        )
        _ = try await world.ledger.submit(walletEnvelope)

        // Ours.
        let outcome = await world.side.creation.completeExternalCreation(groupIDHex: groupIDHex)
        guard case .created(let treasury) = outcome else {
            return XCTFail("completion failed: \(outcome)")
        }
        XCTAssertEqual(treasury.account.accountID, accountID)

        let onChain = try await world.ledger.account(treasury.account)
        XCTAssertNil(TreasuryCreationInteractor.misconfiguration(
            onChain,
            account: treasury.account,
            expectedCoSigners: world.coSigners.map { TreasuryCoSigner(account: $0) },
            expectedThresholds: world.thresholds
        ))
        // The seed dies with the row.
        let pending = await world.side.repository.pendingCreation(groupID: groupIDHex)
        XCTAssertNil(pending)
    }

    /// Run it again and it does not run again. The resume branch reads
    /// the ledger, finds the account already configured, and stops at
    /// "this group has one" rather than submitting a second lockdown.
    func test_completingTwice_anchorsOnceAndStaysAnchored() async throws {
        let world = try await makeExternalWorld()
        try await fundExternally(world)
        guard case .created(let treasury) =
            await world.side.creation.completeExternalCreation(groupIDHex: groupIDHex)
        else { return XCTFail("first completion failed") }

        let again = await world.side.creation.completeExternalCreation(groupIDHex: groupIDHex)
        XCTAssertEqual(again, .alreadyExists)
        let anchored = await world.side.repository.snapshot(groupID: groupIDHex).treasury
        XCTAssertEqual(anchored?.account, treasury.account)
    }

    /// The resume path proper: the configuration landed, the app died
    /// before anchoring. Running again must anchor what is already on
    /// the ledger rather than submit a second transaction the account's
    /// sequence has moved past.
    func test_aConfigurationThatLanded_isAnchoredOnTheNextRun() async throws {
        let world = try await makeExternalWorld()
        try await fundExternally(world)

        // Configure by hand, exactly as the interactor would, then wipe
        // nothing — the pending row still says the job is unfinished.
        let loaded = await world.side.repository.pendingCreation(groupID: groupIDHex)
        let pending = try XCTUnwrap(loaded)
        let seed = try XCTUnwrap(pending.treasurySeed)
        let key = try EphemeralTreasuryKey(seed: seed)
        let account = try await world.ledger.account(pending.treasuryAccount)
        let configuration = try TreasuryTransactionFactory.creationConfiguration(
            treasury: pending.treasuryAccount,
            treasurySequence: account.sequenceNumber,
            coSigners: pending.coSigners,
            thresholds: pending.thresholds,
            baseFee: StellarAmount(stroops: 100),
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 4_000_000_000)
        )
        var envelope = TransactionEnvelope(transaction: configuration)
        try key.sign(&envelope, network: .testnet)
        _ = try await world.ledger.submit(envelope)

        guard case .created(let treasury) =
            await world.side.creation.completeExternalCreation(groupIDHex: groupIDHex)
        else { return XCTFail("the resume branch must anchor what is already configured") }
        XCTAssertEqual(treasury.account, pending.treasuryAccount)
        let cleared = await world.side.repository.pendingCreation(groupID: groupIDHex)
        XCTAssertNil(cleared)
    }

    /// One tap on "Start over" after the wallet has funded the account
    /// used to delete the only key that could ever reach it. It is
    /// refused now, and the row survives the refusal.
    func test_abandoning_isRefusedOnceTheFundingHasLanded() async throws {
        let world = try await makeExternalWorld()
        try await fundExternally(world)

        let outcome = await world.side.creation.abandonExternalCreation(groupIDHex: groupIDHex)
        guard case .accountAlreadyFunded = outcome else {
            return XCTFail("abandoning a funded treasury must be refused, got \(outcome)")
        }
        let pending = await world.side.repository.pendingCreation(groupID: groupIDHex)
        XCTAssertNotNil(pending?.treasurySeed, "the key must survive a refused abandon")

        // And the way out of that state still works.
        guard case .created = await world.side.creation
            .completeExternalCreation(groupIDHex: groupIDHex)
        else { return XCTFail("finishing must still be possible") }
    }

    /// Before the funding lands there is nothing to strand, so it is
    /// discarded — which is the case the button exists for.
    func test_abandoning_isAllowedBeforeTheWalletSendsAnything() async throws {
        let world = try await makeExternalWorld()
        try await handOff(world)
        let outcome = await world.side.creation.abandonExternalCreation(groupIDHex: groupIDHex)
        XCTAssertEqual(outcome, .discarded)
        let pending = await world.side.repository.pendingCreation(groupID: groupIDHex)
        XCTAssertNil(pending)
    }

    /// A handoff begun before the split existed has no seed. It must
    /// still finish, through the path that was written for it.
    func test_aPendingRowWithNoSeed_fallsBackToAdopt() async throws {
        let world = try await makeExternalWorld()
        try await handOff(world)
        let loaded = await world.side.repository.pendingCreation(groupID: groupIDHex)
        let pending = try XCTUnwrap(loaded)
        await world.side.repository.recordPendingCreation(PendingTreasuryCreation(
            groupID: pending.groupID,
            ownerIdentityID: pending.ownerIdentityID,
            treasuryAccount: pending.treasuryAccount,
            network: pending.network,
            creationTxHash: pending.creationTxHash,
            coSigners: pending.coSigners,
            thresholds: pending.thresholds,
            startedAt: pending.startedAt
        ))
        // `adopt` refuses an account that is not on the ledger, which is
        // the honest answer here and proves which path was taken: the
        // split path's message names the wallet, `adopt`'s does not.
        let outcome = await world.side.creation.completeExternalCreation(groupIDHex: groupIDHex)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, "the treasury account is not on the ledger yet")
    }

    /// An unreachable Horizon is not proof that nothing was funded, so
    /// it must not be treated as permission to delete the only key.
    func test_abandoning_refusesWhenTheLedgerCannotBeReached() async throws {
        let world = try await makeExternalWorld()
        try await fundExternally(world)
        let loaded = await world.side.repository.pendingCreation(groupID: groupIDHex)
        let pending = try XCTUnwrap(loaded)

        // A side whose Horizon answers nothing but errors.
        let broken = FakeHorizonClient()
        await broken.setAccountError(.invalidResponse(statusCode: 503, body: "down"))
        let adaLoaded = await ada.currentIdentity()
        let boLoaded = await bo.currentIdentity()
        let adaSelected = await ada.currentSelectedID()
        let adaIdentity = try XCTUnwrap(adaLoaded)
        let offline = try await makeSide(
            identity: ada,
            owner: try XCTUnwrap(adaSelected),
            me: adaIdentity,
            peer: try XCTUnwrap(boLoaded),
            adminBlsHex: adaIdentity.blsPublicKey.hexString,
            adminEd25519Hex: adaIdentity.stellarPublicKey.hexString,
            ledger: broken
        )
        await offline.repository.recordPendingCreation(pending)

        let outcome = await offline.creation.abandonExternalCreation(groupIDHex: groupIDHex)
        XCTAssertEqual(outcome, .couldNotTell)
        let survived = await offline.repository.pendingCreation(groupID: groupIDHex)
        XCTAssertNotNil(survived?.treasurySeed, "an unreachable ledger must not cost the key")
    }

    /// Another admin's anchor lands mid-handoff. The founder's funding
    /// is in an account that cannot become this group's treasury — and
    /// leaving it under an ephemeral key with no route to use it is the
    /// failure to avoid, so it gets configured to the co-signers.
    func test_fundingStrandedByAnotherAnchor_isStillConfigured() async throws {
        let world = try await makeExternalWorld()
        try await fundExternally(world)
        let loaded = await world.side.repository.pendingCreation(groupID: groupIDHex)
        let pending = try XCTUnwrap(loaded)

        // Someone else's treasury, anchored first.
        let other = try StellarAccountID(
            publicKey: Data(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        )
        await world.side.repository.anchor(Treasury(
            account: other,
            groupID: groupIDHex,
            ownerIdentityID: pending.ownerIdentityID,
            network: .testnet,
            creationTxHash: "elsewhere",
            createdAt: Date()
        ))

        let outcome = await world.side.creation.completeExternalCreation(groupIDHex: groupIDHex)
        XCTAssertEqual(outcome, .fundedAnotherAccount(pending.treasuryAccount))

        // Reachable by the co-signers, not by an ephemeral key nobody
        // kept.
        let onChain = try await world.ledger.account(pending.treasuryAccount)
        XCTAssertNil(TreasuryCreationInteractor.misconfiguration(
            onChain,
            account: pending.treasuryAccount,
            expectedCoSigners: pending.coSigners,
            expectedThresholds: pending.thresholds
        ))
        let cleared = await world.side.repository.pendingCreation(groupID: groupIDHex)
        XCTAssertNil(cleared)
    }

    /// Funded to exactly its reserve, a treasury cannot pay for its own
    /// lockdown. That is a sentence, not an opaque submission failure.
    func test_aTreasuryFundedToTheReserve_saysItCannotAffordTheLockdown() async throws {
        let world = try await makeExternalWorld()
        // (2 + 2 signers) × 0.5 XLM, and not one stroop more.
        try await fundExternally(world, stroops: 20_000_000)

        let outcome = await world.side.creation.completeExternalCreation(groupIDHex: groupIDHex)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("does not cover its reserve"), reason)
        // And the row survives, because sending it more is a real fix.
        let pending = await world.side.repository.pendingCreation(groupID: groupIDHex)
        XCTAssertNotNil(pending?.treasurySeed)
    }

    /// The screen prints this sum for a founder to check. It has to be
    /// what the wallet is actually asked for, margin included.
    func test_theEstimate_includesTheMarginTheFundingSends() async throws {
        let world = try await makeExternalWorld()
        let estimate = await world.side.creation.estimate(
            network: .testnet,
            signerCount: 2,
            spendable: StellarAmount(stroops: 0)
        )
        let quoted = try XCTUnwrap(estimate).fee.stroops
        let configuration = TreasuryTransactionFactory.configurationFee(
            signerCount: 2,
            baseFee: StellarAmount(stroops: 100)
        ).stroops * TreasuryCreationInteractor.configurationFeeMargin
        XCTAssertGreaterThanOrEqual(quoted, configuration)
    }

    /// A stranded account that cannot be finished must not be reported
    /// as a treasury. Every failure in that branch used to answer
    /// `.alreadyExists`, which the screen renders as "created" — the
    /// founder told it worked while their XLM sat under a key they were
    /// told was destroyed.
    func test_strandedFunding_thatCannotBeFinished_isNotReportedAsCreated() async throws {
        let world = try await makeExternalWorld()
        try await fundExternally(world)
        let loaded = await world.side.repository.pendingCreation(groupID: groupIDHex)
        let pending = try XCTUnwrap(loaded)

        // Another admin's anchor, and a ledger that refuses the
        // lockdown.
        await world.side.repository.anchor(Treasury(
            account: try StellarAccountID(
                publicKey: Data(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
            ),
            groupID: groupIDHex,
            ownerIdentityID: pending.ownerIdentityID,
            network: .testnet,
            creationTxHash: "elsewhere",
            createdAt: Date()
        ))
        await world.ledger.refuseSubmissions(true)

        let outcome = await world.side.creation.completeExternalCreation(groupIDHex: groupIDHex)
        guard case .failed(let reason) = outcome else {
            return XCTFail("a stranded account that cannot be finished is not a success")
        }
        XCTAssertTrue(reason.contains(pending.treasuryAccount.abbreviated), reason)
        // And the key survives, because the account still needs it.
        let survived = await world.side.repository.pendingCreation(groupID: groupIDHex)
        XCTAssertNotNil(survived?.treasurySeed)
    }

    /// A second `create` must not mint a new key over a handoff that is
    /// already out there — the same loss `abandonExternalCreation`
    /// refuses, reached by a different button.
    func test_creatingTwice_doesNotOverwriteALiveHandoff() async throws {
        let world = try await makeExternalWorld()
        try await handOff(world)
        let loaded = await world.side.repository.pendingCreation(groupID: groupIDHex)
        let first = try XCTUnwrap(loaded)

        let outcome = await world.side.creation.create(
            groupIDHex: groupIDHex,
            funder: world.funder,
            coSigners: world.coSigners.map { TreasuryCoSigner(account: $0) },
            thresholds: world.thresholds,
            spendable: StellarAmount(stroops: 0),
            network: .testnet
        )
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("already waiting"), reason)
        let after = await world.side.repository.pendingCreation(groupID: groupIDHex)
        XCTAssertEqual(after?.treasuryAccount, first.treasuryAccount)
        XCTAssertEqual(after?.treasurySeed, first.treasurySeed)
    }

    /// What the group is told has to resolve on the ledger. When the
    /// configuration landed on an earlier run there is no recorded
    /// hash, and the fallback used to be the *predicted* funding hash a
    /// wallet may have renumbered.
    func test_theAnchoredHash_isOneTheLedgerHolds() async throws {
        let world = try await makeExternalWorld()
        try await fundExternally(world)
        guard case .created(let treasury) =
            await world.side.creation.completeExternalCreation(groupIDHex: groupIDHex)
        else { return XCTFail("completion failed") }

        let history = try await world.ledger.transactions(for: treasury.account, limit: 50)
        XCTAssertTrue(
            history.contains { $0.hash == treasury.creationTxHash && $0.successful },
            "announced \(treasury.creationTxHash), ledger holds \(history.map(\.hash))"
        )
    }

    // MARK: - External-path harness

    private struct ExternalWorld {
        let side: Side
        let ledger: LedgerHorizon
        let funder: StellarAccountID
        let funderKey: Curve25519.Signing.PrivateKey
        let coSigners: [StellarAccountID]
        let thresholds: TreasuryThresholds
    }

    /// A group whose founder funds from an account Onym cannot sign
    /// for — which is what puts `create` on the external path.
    private func makeExternalWorld() async throws -> ExternalWorld {
        let adaLoaded = await ada.currentIdentity()
        let boLoaded = await bo.currentIdentity()
        let adaSelected = await ada.currentSelectedID()
        let adaIdentity = try XCTUnwrap(adaLoaded)
        let boIdentity = try XCTUnwrap(boLoaded)
        let adaOwner = try XCTUnwrap(adaSelected)

        let funderKey = Curve25519.Signing.PrivateKey()
        let funder = try StellarAccountID(
            publicKey: Data(funderKey.publicKey.rawRepresentation)
        )
        let ledger = LedgerHorizon()
        await ledger.create(account: funder, balance: 1_000_000_000)

        let side = try await makeSide(
            identity: ada,
            owner: adaOwner,
            me: adaIdentity,
            peer: boIdentity,
            adminBlsHex: adaIdentity.blsPublicKey.hexString,
            adminEd25519Hex: adaIdentity.stellarPublicKey.hexString,
            ledger: ledger
        )
        // The founder declares the wallet account; the co-signer set is
        // that plus Bo's.
        let boSigner = try StellarAccountID(accountID: boIdentity.treasuryAccountID)
        let declarations: [(StellarAccountID, Identity, IdentityRepository)] = [
            (funder, adaIdentity, ada),
            (boSigner, boIdentity, bo)
        ]
        for (account, identity, repo) in declarations {
            await side.repository.record(TreasurySignerDeclarationRecord(
                groupID: groupIDHex,
                ownerIdentityID: adaOwner,
                memberBlsPubkeyHex: identity.blsPublicKey.hexString,
                account: account,
                source: account == funder ? .external : .onym,
                signature: try sign(
                    identity: repo,
                    account: account,
                    sendingKey: identity.stellarPublicKey
                ),
                declarerSendingPublicKey: identity.stellarPublicKey,
                declaredAt: Date()
            ))
        }
        let world = ExternalWorld(
            side: side,
            ledger: ledger,
            funder: funder,
            funderKey: funderKey,
            coSigners: [funder, boSigner],
            thresholds: TreasuryThresholds(low: 1, medium: 2, high: 2)
        )
        return world
    }

    /// The handoff itself, as its own step — `create` refuses to run
    /// twice over a live one, which is the point of a separate call.
    @discardableResult
    private func handOff(_ world: ExternalWorld) async throws -> SEP0007Request {
        let outcome = await world.side.creation.create(
            groupIDHex: groupIDHex,
            funder: world.funder,
            coSigners: world.coSigners.map { TreasuryCoSigner(account: $0) },
            thresholds: world.thresholds,
            spendable: StellarAmount(stroops: 0),
            network: .testnet
        )
        guard case .needsExternalWallet(let request, _, _) = outcome else {
            struct NotExternal: Error { let outcome: TreasuryCreationOutcome }
            throw NotExternal(outcome: outcome)
        }
        return request
    }

    /// Play the wallet: sign the funding transaction and submit it.
    private func fundExternally(
        _ world: ExternalWorld,
        stroops: Int64 = 40_000_000
    ) async throws {
        if await world.side.repository.pendingCreation(groupID: groupIDHex) == nil {
            try await handOff(world)
        }
        let loaded = await world.side.repository.pendingCreation(groupID: groupIDHex)
        let pending = try XCTUnwrap(loaded)
        let account = try await world.ledger.account(world.funder)
        let funding = try TreasuryTransactionFactory.creationFunding(
            funder: world.funder,
            funderSequence: account.sequenceNumber,
            treasury: pending.treasuryAccount,
            startingBalance: StellarAmount(stroops: stroops),
            baseFee: StellarAmount(stroops: 100),
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 4_000_000_000)
        )
        var envelope = TransactionEnvelope(transaction: funding)
        try envelope.addSignature(
            try world.funderKey.signature(for: funding.hash(network: .testnet)),
            from: world.funder,
            network: .testnet
        )
        _ = try await world.ledger.submit(envelope)
    }

    /// The fake refuses what the network refuses — the three checks it
    /// was missing, each of which could otherwise let a future change
    /// look correct against a more permissive ledger than production.
    func test_theLedgerRefusesExpiredUnderfundedAndUnaffordable() async throws {
        let loaded = await ada.currentIdentity()
        let adaIdentity = try XCTUnwrap(loaded)
        let signer = try StellarAccountID(accountID: adaIdentity.treasuryAccountID)
        let treasuryAccount = TreasuryTestKeys.account(80)
        let recipient = TreasuryTestKeys.account(81)

        func ledgerWithTreasury(balance: Int64) async -> LedgerHorizon {
            let ledger = LedgerHorizon()
            await ledger.create(account: treasuryAccount, balance: balance)
            await ledger.setControl(
                of: treasuryAccount,
                signers: [signer.accountID: 1],
                thresholds: HorizonThresholds(low: 1, medium: 1, high: 1)
            )
            await ledger.create(account: recipient, balance: 10_000_000)
            return ledger
        }

        func signedPayment(
            stroops: Int64,
            fee: UInt32 = 100,
            maxTime: UInt64 = 4_000_000_000
        ) async throws -> TransactionEnvelope {
            let transaction = try StellarTransaction(
                sourceAccount: treasuryAccount,
                fee: fee,
                sequenceNumber: 2,
                timeBounds: StellarTimeBounds(minTime: 0, maxTime: maxTime),
                operations: [
                    StellarOperation(body: .payment(
                        destination: recipient,
                        asset: .native,
                        amount: StellarAmount(stroops: stroops)
                    )),
                ]
            )
            var envelope = TransactionEnvelope(transaction: transaction)
            let signature = try await ada.signWithTreasuryKey(
                transaction.hash(network: .testnet)
            )
            try envelope.addSignature(signature, from: signer, network: .testnet)
            return envelope
        }

        func codes(from error: Error) -> [String] {
            guard case HorizonError.submissionFailed(let codes, _) = error else { return [] }
            return codes
        }

        // Past its time bound. The ledger's clock is moved rather than
        // the envelope's bound, because a bound in the past is one the
        // proposal verifier would have refused long before this.
        let expiredLedger = await ledgerWithTreasury(balance: 100_000_000)
        await expiredLedger.setNow { Date(timeIntervalSince1970: 4_000_000_001) }
        do {
            _ = try await expiredLedger.submit(try await signedPayment(stroops: 1_000))
            XCTFail("the ledger accepted an expired transaction")
        } catch {
            XCTAssertEqual(codes(from: error), ["tx_too_late"])
        }

        // Spending into the reserve. The balance covers the amount on
        // its face and does not cover it once the account's minimum is
        // taken out, which is the arithmetic the treasury screen shows.
        let poorLedger = await ledgerWithTreasury(balance: 20_000_000)
        do {
            _ = try await poorLedger.submit(try await signedPayment(stroops: 19_000_000))
            XCTFail("the ledger accepted a payment that spends the reserve")
        } catch {
            XCTAssertEqual(codes(from: error), ["tx_failed", "op_underfunded"])
        }

        // And the fee is a real debit, taken from the source whatever
        // else happens.
        let payingLedger = await ledgerWithTreasury(balance: 100_000_000)
        _ = try await payingLedger.submit(try await signedPayment(stroops: 1_000, fee: 5_000))
        let after = try await payingLedger.account(treasuryAccount)
        let balance = try XCTUnwrap(after.balances.first { $0.asset == .native })
        XCTAssertEqual(balance.balance.stroops, 100_000_000 - 1_000 - 5_000)
    }

    /// A proposal spending an account that is not this group's treasury
    /// is refused on arrival — the rule that stops a member collecting
    /// the group's signatures for their own transaction.
    func test_aProposalSpendingAnotherAccount_isRefusedOnArrival() async throws {
        let adaLoaded = await ada.currentIdentity()
        let boLoaded = await bo.currentIdentity()
        let boSelected = await bo.currentSelectedID()
        let adaIdentity = try XCTUnwrap(adaLoaded)
        let boIdentity = try XCTUnwrap(boLoaded)
        let boOwner = try XCTUnwrap(boSelected)

        let ledger = LedgerHorizon()
        let boSide = try await makeSide(
            identity: bo,
            owner: boOwner,
            me: boIdentity,
            peer: adaIdentity,
            adminBlsHex: adaIdentity.blsPublicKey.hexString,
            adminEd25519Hex: adaIdentity.stellarPublicKey.hexString,
            ledger: ledger
        )
        let treasuryAccount = TreasuryTestKeys.account(60)
        await boSide.repository.anchor(Treasury(
            account: treasuryAccount,
            groupID: groupIDHex,
            ownerIdentityID: boOwner,
            network: .testnet,
            creationTxHash: "hash",
            createdAt: Date()
        ))

        // Ada's own account, not the treasury.
        let rogue = TransactionEnvelope(transaction: try StellarTransaction(
            sourceAccount: TreasuryTestKeys.account(61),
            fee: 100,
            sequenceNumber: 2,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 4_000_000_000),
            operations: [
                StellarOperation(body: .payment(
                    destination: TreasuryTestKeys.account(62),
                    asset: .native,
                    amount: StellarAmount(stroops: 1)
                )),
            ]
        ))
        let id = UUID()
        await boSide.receiver.apply(
            TreasuryProposalPayload(
                groupID: groupIDData,
                proposalID: id,
                proposerBlsPubkeyHex: adaIdentity.blsPublicKey.hexString,
                xdr: rogue.base64XDR,
                networkPassphrase: StellarNetwork.testnet.passphrase,
                sentAtMillis: 1
            ),
            ownerIdentityID: boOwner,
            senderEd25519PublicKey: adaIdentity.stellarPublicKey
        )

        let rogueFetched = await boSide.repository.proposal(id: id)
        let stored = try XCTUnwrap(rogueFetched)
        XCTAssertEqual(stored.rejection, .notThisTreasury)
    }

    // MARK: - Wiring

    private struct Side {
        let identity: IdentityRepository
        let owner: IdentityID
        let repository: TreasuryRepository
        let receiver: TreasuryPayloadReceiver
        let creation: TreasuryCreationInteractor
        let proposing: TreasuryProposalInteractor
        let signing: TreasurySigningInteractor
    }

    private func makeSide(
        identity: IdentityRepository,
        owner: IdentityID,
        me: Identity,
        peer: Identity,
        adminBlsHex: String,
        adminEd25519Hex: String,
        ledger: any HorizonClient
    ) async throws -> Side {
        let groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        await groups.setCurrentIdentity(owner)
        var group = ChatGroup(
            id: groupIDHex,
            ownerIdentityID: owner,
            name: "Flat",
            groupSecret: Data(repeating: 1, count: 32),
            createdAt: Date(),
            members: [],
            memberProfiles: [:],
            epoch: 0,
            salt: Data(repeating: 2, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: nil,
            adminEd25519PubkeyHex: adminEd25519Hex,
            isPublishedOnChain: true
        )
        // Both sides see the same two-person roster, and agree on who
        // founded it — creation is admin-gated, and Bo's copy has to
        // name the same admin or the two would disagree about whether
        // Ada was allowed to set the treasury up.
        group.adminPubkeyHex = adminBlsHex
        group.memberProfiles = [
            me.blsPublicKey.hexString: MemberProfile(
                alias: "Me",
                inboxPublicKey: me.inboxPublicKey,
                sendingPubkey: me.stellarPublicKey
            ),
            peer.blsPublicKey.hexString: MemberProfile(
                alias: "Peer",
                inboxPublicKey: peer.inboxPublicKey,
                sendingPubkey: peer.stellarPublicKey
            ),
        ]
        await groups.insert(group)

        let store = InMemoryTreasuryStore()
        let repository = TreasuryRepository(store: store, horizon: { _ in ledger })
        await repository.setCurrentIdentity(owner)

        // No broadcaster fan-out in this test: the payload leg is
        // carried by hand, so a broadcaster with a no-op transport
        // would only add noise. Every state change is still driven
        // through the real repository and interactors.
        let broadcaster = TreasuryBroadcaster(
            identity: identity,
            inboxTransport: FakeInboxTransport(),
            groups: groups,
            treasury: repository
        )
        return Side(
            identity: identity,
            owner: owner,
            repository: repository,
            receiver: TreasuryPayloadReceiver(treasury: repository, groups: groups),
            creation: TreasuryCreationInteractor(
                treasury: repository,
                identity: identity,
                groups: groups,
                broadcaster: broadcaster,
                horizon: { _ in ledger }
            ),
            proposing: TreasuryProposalInteractor(
                treasury: repository,
                identity: identity,
                broadcaster: broadcaster,
                horizon: { _ in ledger }
            ),
            signing: TreasurySigningInteractor(
                treasury: repository,
                identity: identity,
                broadcaster: broadcaster,
                horizon: { _ in ledger }
            )
        )
    }

    private func sign(
        identity: IdentityRepository,
        account: StellarAccountID,
        sendingKey: Data
    ) async throws -> Data {
        try await identity.signWithStellarKey(
            TreasurySignerDeclaration.statement(
                groupID: groupIDData,
                signerAccount: account,
                declarerSendingPublicKey: sendingKey
            )
        )
    }
}

/// A Horizon that applies what it is given.
///
/// Not a stub returning canned answers: `submit` interprets the
/// operations, so the signer set, thresholds, sequence number and
/// balances the test reads afterwards are the ones the transaction
/// actually wrote. A fake that merely said "ok" would let a creation
/// transaction with its operations in the wrong order pass.
private actor LedgerHorizon: HorizonClient {
    /// The network this ledger stands for. Was hardcoded to testnet in
    /// the returned hash while the authorisation checks used it too.
    private let network: StellarNetwork = .testnet

    private struct Account {
        var sequence: Int64 = 0
        var balances: [String: Int64] = [:]
        var signers: [String: UInt32] = [:]
        var thresholds = HorizonThresholds(low: 0, medium: 0, high: 0)
        var key: StellarAccountID
    }

    private var accounts: [String: Account] = [:]
    /// When set, every submission is refused — for the tests that need
    /// a transaction the network will not take.
    private var refusesSubmissions = false
    private var applied: [(accounts: Set<String>, transaction: HorizonTransaction)] = []

    /// The ledger's clock, so a test can move past a time bound without
    /// waiting for one. Defaults to the real one.
    var now: () -> Date = { Date() }

    func setNow(_ clock: @escaping @Sendable () -> Date) { now = clock }

    func refuseSubmissions(_ refuses: Bool) { refusesSubmissions = refuses }

    /// What the acting account requires for this operation. Matches the
    /// protocol's classes: payments and trustlines are medium, anything
    /// that changes control is high.
    private func threshold(for operation: StellarOperation, on account: Account) -> UInt32 {
        switch operation.body {
        case .setOptions:
            return max(account.thresholds.high, 1)
        case .payment, .changeTrust:
            return max(account.thresholds.medium, 1)
        case .createAccount:
            // Medium, which is where the protocol puts it. Harmless in
            // these tests — every account is 1/1/1 at that point — but
            // wrong in a fake whose stated job is refusing what the
            // network refuses.
            return max(account.thresholds.medium, 1)
        }
    }

    func create(account: StellarAccountID, balance: Int64) {
        accounts[account.accountID] = Account(
            sequence: 1,
            balances: ["XLM": balance],
            // A fresh account is controlled by its own key at weight 1.
            signers: [account.accountID: 1],
            thresholds: HorizonThresholds(low: 1, medium: 1, high: 1),
            key: account
        )
    }

    /// Set an account's signers and thresholds directly, for tests that
    /// need a configured treasury without running creation.
    func setControl(
        of account: StellarAccountID,
        signers: [String: UInt32],
        thresholds: HorizonThresholds
    ) {
        accounts[account.accountID]?.signers = signers
        accounts[account.accountID]?.thresholds = thresholds
    }

    func account(_ id: StellarAccountID) async throws -> HorizonAccount {
        guard let account = accounts[id.accountID] else {
            throw HorizonError.accountNotFound(id.accountID)
        }
        return HorizonAccount(
            accountID: account.key,
            sequenceNumber: account.sequence,
            balances: account.balances.map { code, amount in
                HorizonBalance(
                    // The code was being discarded, so every balance
                    // reported as the native asset.
                    asset: code == "XLM"
                        ? .native
                        : ((try? StellarAsset(code: code, issuer: account.key)) ?? .native),
                    balance: StellarAmount(stroops: amount),
                    limit: nil
                )
            },
            signers: account.signers.compactMap { key, weight in
                guard let id = try? StellarAccountID(accountID: key) else { return nil }
                return StellarSigner(key: id, weight: weight)
            },
            thresholds: account.thresholds
        )
    }

    /// Applied transactions involving `id`, newest first.
    ///
    /// Recorded rather than returned empty, because "the ledger holds
    /// no history" is not a thing a real Horizon says about an account
    /// that exists — and the anchor path now refuses to announce a hash
    /// the ledger cannot confirm. A fake that forgets every transaction
    /// it applied would make that refusal fire on correct behaviour.
    func transactions(for id: StellarAccountID, limit: Int) async throws -> [HorizonTransaction] {
        applied
            .filter { $0.accounts.contains(id.accountID) }
            .suffix(limit)
            .reversed()
            .map(\.transaction)
    }

    func networkParameters() async throws -> HorizonNetworkParameters {
        HorizonNetworkParameters(
            baseFee: StellarAmount(stroops: 100),
            baseReserve: StellarAmount(stroops: 5_000_000)
        )
    }

    func submit(_ envelope: TransactionEnvelope) async throws -> String {
        if refusesSubmissions {
            throw HorizonError.submissionFailed(resultCodes: ["tx_failed"], body: "refused")
        }
        // Snapshot, so a rejected transaction leaves nothing behind.
        //
        // Operations were applied one at a time with no rollback, so
        // after the `tx_bad_auth` in the lockdown-first test the
        // treasury existed half-configured — and "applies whole or not
        // at all" is the property the creation design rests on, which
        // makes it the last thing this fake should get wrong.
        let restore = accounts
        do {
            return try apply(envelope)
        } catch {
            accounts = restore
            throw error
        }
    }

    private func apply(_ envelope: TransactionEnvelope) throws -> String {
        let transaction = envelope.transaction
        let sourceID = transaction.sourceAccount.accountID
        guard var source = accounts[sourceID] else {
            throw HorizonError.accountNotFound(sourceID)
        }
        guard transaction.sequenceNumber == source.sequence + 1 else {
            throw HorizonError.submissionFailed(resultCodes: ["tx_bad_seq"], body: "")
        }

        // An envelope past its time bound is `tx_too_late`, and until
        // now this fake ignored bounds entirely — so an expired
        // transaction submitted happily. Of all the gaps to leave in a
        // fake, that is the one most likely to make a future test pass
        // for the wrong reason: a great deal of this design rests on
        // time bounds, and a ledger that does not enforce them would
        // let a change removing them look correct.
        if let bounds = transaction.timeBounds, bounds.maxTime != 0 {
            let deadline = Date(timeIntervalSince1970: TimeInterval(bounds.maxTime))
            if now() > deadline {
                throw HorizonError.submissionFailed(
                    resultCodes: ["tx_too_late"],
                    body: "maxTime \(bounds.maxTime)"
                )
            }
        }

        // The fee is debited from the source whatever happens next, and
        // it has to be there to begin with.
        guard (source.balances["XLM"] ?? 0) >= Int64(transaction.fee) else {
            throw HorizonError.submissionFailed(resultCodes: ["tx_insufficient_fee"], body: "")
        }

        // Each operation is authorised against the account state *at
        // that point in the transaction*, then applied — which is what
        // makes operation order observable.
        //
        // The fake used to skip authorisation entirely, so its
        // docstring's claim was not delivered: moving the lockdown
        // ahead of the signer installs left every assertion passing,
        // and the payment applied with no signatures at all.
        for operation in transaction.operations {
            let actingID = operation.sourceAccount?.accountID ?? sourceID
            // An operation naming an account that does not exist yet is
            // `op_no_account`, not something to skip silently — which
            // let a creation with its `setOptions` ops *before* the
            // `createAccount` submit successfully with them dropped.
            guard let acting = accounts[actingID] else {
                throw HorizonError.submissionFailed(
                    resultCodes: ["op_no_account"],
                    body: actingID
                )
            }
            let required = threshold(for: operation, on: acting)
            let weight = acting.signers.reduce(UInt32(0)) { total, entry in
                guard let key = try? StellarAccountID(accountID: entry.key),
                      envelope.hasSignature(from: key, network: network)
                else { return total }
                return total + entry.value
            }
            guard weight >= required else {
                throw HorizonError.submissionFailed(
                    resultCodes: ["tx_bad_auth"],
                    body: "\(actingID) needs \(required), has \(weight)"
                )
            }

            switch operation.body {
            case .createAccount(let destination, let startingBalance):
                accounts[destination.accountID] = Account(
                    sequence: 1,
                    balances: ["XLM": startingBalance.stroops],
                    signers: [destination.accountID: 1],
                    thresholds: HorizonThresholds(low: 1, medium: 1, high: 1),
                    key: destination
                )
                accounts[actingID]?.balances["XLM", default: 0] -= startingBalance.stroops

            case .payment(let destination, _, let amount):
                // Real Horizon answers `op_no_destination` for an
                // unfunded destination. The fake used to invent the
                // account, which meant the E2E asserted a payment that
                // the network would have refused.
                guard accounts[destination.accountID] != nil else {
                    throw HorizonError.submissionFailed(
                        resultCodes: ["op_no_destination"],
                        body: destination.accountID
                    )
                }
                // Spendable is the balance minus the reserve Stellar
                // locks while the account exists. Without this the fake
                // applied a payment that emptied an account past its
                // minimum — `op_underfunded` on the real network — and
                // the treasury screen's whole "spendable" arithmetic
                // could have been wrong with every test green.
                let acting = accounts[actingID]
                let reserve = Self.minimumBalance(of: acting)
                let available = (acting?.balances["XLM"] ?? 0)
                    - reserve
                    - Int64(transaction.fee)
                guard available >= amount.stroops else {
                    throw HorizonError.submissionFailed(
                        resultCodes: ["tx_failed", "op_underfunded"],
                        body: "\(actingID) has \(available) spendable"
                    )
                }
                accounts[actingID]?.balances["XLM", default: 0] -= amount.stroops
                accounts[destination.accountID]?.balances["XLM", default: 0] += amount.stroops

            case .setOptions(let fields):
                guard var acting = accounts[actingID] else { break }
                if let signer = fields.signer {
                    if signer.weight == 0 {
                        acting.signers.removeValue(forKey: signer.key.accountID)
                    } else {
                        acting.signers[signer.key.accountID] = signer.weight
                    }
                }
                if let master = fields.masterWeight {
                    acting.signers[actingID] = master
                }
                acting.thresholds = HorizonThresholds(
                    low: fields.lowThreshold ?? acting.thresholds.low,
                    medium: fields.mediumThreshold ?? acting.thresholds.medium,
                    high: fields.highThreshold ?? acting.thresholds.high
                )
                accounts[actingID] = acting

            case .changeTrust:
                break
            }
        }

        source = accounts[sourceID] ?? source
        source.sequence = transaction.sequenceNumber
        source.balances["XLM", default: 0] -= Int64(transaction.fee)
        accounts[sourceID] = source

        let hash = transaction.hash(network: network).hexString
        var touched: Set<String> = [sourceID]
        for operation in transaction.operations {
            if let opSource = operation.sourceAccount?.accountID { touched.insert(opSource) }
            switch operation.body {
            case .createAccount(let destination, _): touched.insert(destination.accountID)
            case .payment(let destination, _, _): touched.insert(destination.accountID)
            case .setOptions, .changeTrust: break
            }
        }
        applied.append((
            accounts: touched,
            transaction: HorizonTransaction(
                hash: hash,
                ledgerCloseTime: now(),
                sourceAccount: transaction.sourceAccount,
                successful: true,
                feeCharged: StellarAmount(stroops: Int64(transaction.fee)),
                envelopeXDR: envelope.base64XDR
            )
        ))
        return hash
    }

    /// `(2 + subentries) × baseReserve`, with signers beyond the master
    /// key as the subentries this fake models.
    private static func minimumBalance(of account: Account?) -> Int64 {
        guard let account else { return 0 }
        let subentries = Int64(max(account.signers.count - 1, 0))
        return (2 + subentries) * 5_000_000
    }
}
