import CryptoKit
import Foundation
import XCTest
@testable import OnymIOS
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
            adminBlsHex: adaIdentity.blsPublicKey.hex,
            adminEd25519Hex: adaIdentity.stellarPublicKey.hex,
            ledger: ledger
        )
        let boSide = try await makeSide(
            identity: bo,
            owner: boOwner,
            me: boIdentity,
            peer: adaIdentity,
            adminBlsHex: adaIdentity.blsPublicKey.hex,
            adminEd25519Hex: adaIdentity.stellarPublicKey.hex,
            ledger: ledger
        )

        // 1. Both declare which Stellar account speaks for them.
        for (side, identity) in [(adaSide, adaIdentity), (boSide, boIdentity)] {
            let account = try StellarAccountID(accountID: identity.treasuryAccountID)
            await side.repository.record(TreasurySignerDeclarationRecord(
                groupID: groupIDHex,
                ownerIdentityID: side.owner,
                memberBlsPubkeyHex: identity.blsPublicKey.hex,
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
            memberBlsPubkeyHex: boIdentity.blsPublicKey.hex,
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
            coSigners: [adaSigner, boSigner],
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
        let masterWeight = onChain.signers
            .first { $0.key == treasury.account }
            .map(\.weight) ?? 0
        XCTAssertEqual(masterWeight, 0, "the treasury's own key must be switched off")
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
        let recipient = TreasuryTestKeys.account(77)
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
                proposerBlsPubkeyHex: adaIdentity.blsPublicKey.hex,
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
        XCTAssertEqual(description.title, "Pay 5 XLM")
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
            adminBlsHex: adaIdentity.blsPublicKey.hex,
            adminEd25519Hex: adaIdentity.stellarPublicKey.hex,
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
                proposerBlsPubkeyHex: adaIdentity.blsPublicKey.hex,
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
        ledger: LedgerHorizon
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
            me.blsPublicKey.hex: MemberProfile(
                alias: "Me",
                inboxPublicKey: me.inboxPublicKey,
                sendingPubkey: me.stellarPublicKey
            ),
            peer.blsPublicKey.hex: MemberProfile(
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

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// A Horizon that applies what it is given.
///
/// Not a stub returning canned answers: `submit` interprets the
/// operations, so the signer set, thresholds, sequence number and
/// balances the test reads afterwards are the ones the transaction
/// actually wrote. A fake that merely said "ok" would let a creation
/// transaction with its operations in the wrong order pass.
private actor LedgerHorizon: HorizonClient {
    private struct Account {
        var sequence: Int64 = 0
        var balances: [String: Int64] = [:]
        var signers: [String: UInt32] = [:]
        var thresholds = HorizonThresholds(low: 0, medium: 0, high: 0)
        var key: StellarAccountID
    }

    private var accounts: [String: Account] = [:]

    func create(account: StellarAccountID, balance: Int64) {
        accounts[account.accountID] = Account(
            sequence: 1,
            balances: ["XLM": balance],
            // A fresh account is controlled by its own key at weight 1.
            signers: [account.accountID: 1],
            key: account
        )
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
                    asset: .native,
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

    func transactions(for id: StellarAccountID, limit: Int) async throws -> [HorizonTransaction] {
        []
    }

    func networkParameters() async throws -> HorizonNetworkParameters {
        HorizonNetworkParameters(
            baseFee: StellarAmount(stroops: 100),
            baseReserve: StellarAmount(stroops: 5_000_000)
        )
    }

    func submit(_ envelope: TransactionEnvelope) async throws -> String {
        let transaction = envelope.transaction
        let sourceID = transaction.sourceAccount.accountID
        guard var source = accounts[sourceID] else {
            throw HorizonError.accountNotFound(sourceID)
        }
        guard transaction.sequenceNumber == source.sequence + 1 else {
            throw HorizonError.submissionFailed(resultCodes: ["tx_bad_seq"], body: "")
        }

        for operation in transaction.operations {
            let actingID = operation.sourceAccount?.accountID ?? sourceID
            switch operation.body {
            case .createAccount(let destination, let startingBalance):
                accounts[destination.accountID] = Account(
                    sequence: 1,
                    balances: ["XLM": startingBalance.stroops],
                    signers: [destination.accountID: 1],
                    key: destination
                )
                accounts[actingID]?.balances["XLM", default: 0] -= startingBalance.stroops

            case .payment(let destination, _, let amount):
                accounts[actingID]?.balances["XLM", default: 0] -= amount.stroops
                if accounts[destination.accountID] == nil {
                    accounts[destination.accountID] = Account(key: destination)
                }
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
                    if master == 0 {
                        acting.signers[actingID] = 0
                    } else {
                        acting.signers[actingID] = master
                    }
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
        accounts[sourceID] = source
        return transaction.hash(network: .testnet).map { String(format: "%02x", $0) }.joined()
    }
}
