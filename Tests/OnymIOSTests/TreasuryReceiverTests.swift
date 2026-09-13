import CryptoKit
import XCTest
@testable import OnymIOS
import OnymGroup
import OnymIdentity
import OnymStellar
import OnymTreasury

/// The receiver's provenance gates.
///
/// Every one of these had only a happy path: delete the admin check and
/// all sixty-seven tests still passed. "A member points the group at an
/// account they control" is the same class of harm as the verifier
/// refusals the suite already covers, so it gets the same treatment —
/// a negative test each.
@MainActor
final class TreasuryReceiverTests: XCTestCase {

    private let groupIDHex = String(repeating: "7e", count: 32)
    private var groupIDData: Data { Data(repeating: 0x7e, count: 32) }
    private let owner = IdentityID(UUID())

    private let adminKey = TreasuryTestKeys.key(50)
    private let memberKey = TreasuryTestKeys.key(51)
    private var adminPub: Data { Data(adminKey.publicKey.rawRepresentation) }
    private var memberPub: Data { Data(memberKey.publicKey.rawRepresentation) }

    /// A bound inside the window `TreasuryProposalVerifier` permits. A
    /// far-future one is now refused outright — that is the rule that
    /// stops a proposal holding the treasury's next sequence number
    /// forever.
    private static var soon: StellarTimeBounds {
        StellarTimeBounds(
            minTime: 0,
            maxTime: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        )
    }

    private let treasuryAccount = TreasuryTestKeys.account(52)
    private let rogueAccount = TreasuryTestKeys.account(53)

    // MARK: - Anchor

    /// The gate that stops a member pointing the group at an account
    /// they control.
    func test_anAnchorFromANonAdmin_isIgnored() async throws {
        let (repository, receiver) = await make()
        await receiver.apply(
            anchorPayload(account: rogueAccount),
            ownerIdentityID: owner,
            // A real member's key, but not the admin's.
            senderEd25519PublicKey: memberPub
        )
        let anchored = await repository.snapshot(groupID: groupIDHex).treasury
        XCTAssertNil(anchored, "a non-admin anchored a treasury")
    }

    /// An envelope that shipped without a signature cannot be
    /// attributed to anyone, so it cannot be an admin's.
    func test_anAnchorWithNoSender_isIgnored() async throws {
        let (repository, receiver) = await make()
        await receiver.apply(
            anchorPayload(account: treasuryAccount),
            ownerIdentityID: owner,
            senderEd25519PublicKey: nil
        )
        let anchored = await repository.snapshot(groupID: groupIDHex).treasury
        XCTAssertNil(anchored)
    }

    func test_anAnchorFromTheAdmin_isAdopted() async throws {
        let (repository, receiver) = await make()
        await receiver.apply(
            anchorPayload(account: treasuryAccount),
            ownerIdentityID: owner,
            senderEd25519PublicKey: adminPub
        )
        let anchored = await repository.snapshot(groupID: groupIDHex).treasury
        XCTAssertEqual(anchored?.account, treasuryAccount)
    }

    /// Re-anchoring would let a compromised or careless founder
    /// redirect the group, and every later proposal would verify
    /// cleanly against the new account.
    func test_aSecondAnchor_cannotRedirectTheGroup() async throws {
        let (repository, receiver) = await make()
        await receiver.apply(
            anchorPayload(account: treasuryAccount),
            ownerIdentityID: owner,
            senderEd25519PublicKey: adminPub
        )
        await receiver.apply(
            anchorPayload(account: rogueAccount),
            ownerIdentityID: owner,
            senderEd25519PublicKey: adminPub
        )
        let anchored = await repository.snapshot(groupID: groupIDHex).treasury
        XCTAssertEqual(anchored?.account, treasuryAccount, "the treasury was redirected")
    }

    // MARK: - Declaration

    /// Without this, any member could declare an account on another's
    /// behalf — handing a stranger a seat, or deadlocking the treasury
    /// with an account nobody holds.
    func test_aDeclarationSealedBySomeoneElse_isIgnored() async throws {
        let (repository, receiver) = await make()
        // Claims to be the admin; sealed by the member.
        await receiver.apply(
            declarationPayload(declarer: "aa", account: rogueAccount, signedBy: adminKey),
            ownerIdentityID: owner,
            senderEd25519PublicKey: memberPub
        )
        let declarations = await repository.snapshot(groupID: groupIDHex).declarations
        XCTAssertTrue(declarations.isEmpty)
    }

    /// The detached signature is what makes a declaration showable to a
    /// third party; the envelope only says who sent it.
    func test_aDeclarationWhoseSignatureDoesNotVerify_isIgnored() async throws {
        let (repository, receiver) = await make()
        await receiver.apply(
            declarationPayload(
                declarer: "aa",
                account: rogueAccount,
                signature: Data(repeating: 0, count: 64)
            ),
            ownerIdentityID: owner,
            senderEd25519PublicKey: adminPub
        )
        let declarations = await repository.snapshot(groupID: groupIDHex).declarations
        XCTAssertTrue(declarations.isEmpty)
    }

    func test_aGenuineDeclaration_isRecorded() async throws {
        let (repository, receiver) = await make()
        await receiver.apply(
            declarationPayload(declarer: "aa", account: rogueAccount, signedBy: adminKey),
            ownerIdentityID: owner,
            senderEd25519PublicKey: adminPub
        )
        let declarations = await repository.snapshot(groupID: groupIDHex).declarations
        XCTAssertEqual(declarations.first?.account, rogueAccount)
    }

    // MARK: - Proposal id reuse

    /// The finding from #330's review: a sender-chosen id, upserted on
    /// `(id, owner)`, let a member overwrite an honest member's stored
    /// proposal. First arrival wins.
    func test_aSecondProposalReusingAnId_cannotOverwriteTheFirst() async throws {
        let (repository, receiver) = await make(anchored: true)
        let id = UUID()

        await receiver.apply(
            proposalPayload(id: id, proposer: "aa", amount: 1_000),
            ownerIdentityID: owner,
            senderEd25519PublicKey: adminPub
        )
        let first = await repository.proposal(id: id)
        XCTAssertNil(first?.rejection)

        // Same id, a different amount, from the other member.
        await receiver.apply(
            proposalPayload(id: id, proposer: "bb", amount: 999_999_999),
            ownerIdentityID: owner,
            senderEd25519PublicKey: memberPub
        )
        let after = await repository.proposal(id: id)
        XCTAssertEqual(
            after?.proposal.proposerBlsPubkeyHex,
            "aa",
            "the second proposal took over the first one's row"
        )
        guard case .payment(_, _, let amount) = after?.proposal.operations.first?.body else {
            return XCTFail("expected a payment")
        }
        XCTAssertEqual(amount.stroops, 1_000)
    }

    /// The sender-binding check, on the proposal path.
    func test_aProposalSealedBySomeoneElse_isIgnored() async throws {
        let (repository, receiver) = await make(anchored: true)
        let id = UUID()
        await receiver.apply(
            proposalPayload(id: id, proposer: "aa", amount: 1_000),
            ownerIdentityID: owner,
            senderEd25519PublicKey: memberPub
        )
        let stored = await repository.proposal(id: id)
        XCTAssertNil(stored)
    }

    // MARK: - Wiring

    private func make(
        anchored: Bool = false
    ) async -> (TreasuryRepository, TreasuryPayloadReceiver) {
        let store = InMemoryTreasuryStore()
        let horizon = FakeHorizonClient()
        await horizon.setAccount(HorizonAccount(
            accountID: treasuryAccount,
            sequenceNumber: 1,
            balances: [],
            signers: [],
            thresholds: HorizonThresholds(low: 1, medium: 1, high: 1)
        ))
        let repository = TreasuryRepository(store: store, horizon: { _ in horizon })
        await repository.setCurrentIdentity(owner)

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
            adminPubkeyHex: "aa",
            adminEd25519PubkeyHex: adminPub.hexString,
            isPublishedOnChain: true
        )
        group.memberProfiles = [
            "aa": MemberProfile(
                alias: "Ada",
                inboxPublicKey: Data(repeating: 3, count: 32),
                sendingPubkey: adminPub
            ),
            "bb": MemberProfile(
                alias: "Bo",
                inboxPublicKey: Data(repeating: 4, count: 32),
                sendingPubkey: memberPub
            ),
        ]
        await groups.insert(group)

        if anchored {
            await repository.anchor(Treasury(
                account: treasuryAccount,
                groupID: groupIDHex,
                ownerIdentityID: owner,
                network: .testnet,
                creationTxHash: "hash",
                createdAt: Date()
            ))
        }
        return (repository, TreasuryPayloadReceiver(treasury: repository, groups: groups))
    }

    private func anchorPayload(account: StellarAccountID) -> TreasuryAnchorPayload {
        TreasuryAnchorPayload(
            groupID: groupIDData,
            treasuryAccountID: account.accountID,
            networkPassphrase: StellarNetwork.testnet.passphrase,
            creationTxHash: "hash",
            sentAtMillis: 1
        )
    }

    private func declarationPayload(
        declarer: String,
        account: StellarAccountID,
        signedBy key: Curve25519.Signing.PrivateKey? = nil,
        signature override: Data? = nil
    ) -> TreasurySignerDeclarationPayload {
        let bytes = override ?? (try? key?.signature(
            for: TreasurySignerDeclaration.statement(
                groupID: groupIDData,
                signerAccount: account,
                declarerSendingPublicKey: Data(key!.publicKey.rawRepresentation)
            )
        )) ?? Data(repeating: 0, count: 64)
        return TreasurySignerDeclarationPayload(
            groupID: groupIDData,
            declarerBlsPubkeyHex: declarer,
            signerAccountID: account.accountID,
            source: .external,
            sentAtMillis: 1,
            signature: bytes
        )
    }

    private func proposalPayload(
        id: UUID,
        proposer: String,
        amount: Int64
    ) -> TreasuryProposalPayload {
        // swiftlint:disable:next force_try
        let transaction = try! StellarTransaction(
            sourceAccount: treasuryAccount,
            fee: 100,
            sequenceNumber: 2,
            timeBounds: Self.soon,
            operations: [
                StellarOperation(body: .payment(
                    destination: rogueAccount,
                    asset: .native,
                    amount: StellarAmount(stroops: amount)
                )),
            ]
        )
        return TreasuryProposalPayload(
            groupID: groupIDData,
            proposalID: id,
            proposerBlsPubkeyHex: proposer,
            xdr: TransactionEnvelope(transaction: transaction).base64XDR,
            networkPassphrase: StellarNetwork.testnet.passphrase,
            sentAtMillis: 1
        )
    }
}
