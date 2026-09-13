import CryptoKit
import XCTest
@testable import OnymIOS
import OnymChain
import OnymGroup
import OnymIdentity
import OnymStellar
import OnymTreasury

/// What a device will and will not put in front of a co-signer.
///
/// These are the tests the design is for. A member of the group can
/// send any bytes they like, and everything that gets past
/// `TreasuryProposalVerifier` is rendered as a thing worth signing — so
/// each refusal here corresponds to a way someone could otherwise be
/// induced to authorise something they did not read.
final class TreasuryVerifierTests: XCTestCase {

    /// Inside the lifetime the verifier permits — see
    /// `test_aProposalWithNoTimeBound_isRefused` for why an unbounded
    /// one is not merely untidy.
    static var soon: StellarTimeBounds {
        StellarTimeBounds(
            minTime: 0,
            maxTime: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        )
    }

    private let treasuryAccount = TreasuryTestKeys.account(9)
    private let stranger = TreasuryTestKeys.account(8)
    private let owner = IdentityID(UUID())
    private let groupIDHex = String(repeating: "ab", count: 32)

    // MARK: - Refusals

    func test_aTransactionSpendingSomeOtherAccount_isRefused() throws {
        // The single most valuable check: without it, "pay 1000 XLM" out
        // of an account the group does not own still collects this
        // group's signatures — and those signatures are just as valid
        // for that account.
        let envelope = try envelope(source: stranger, operations: [payment()])
        XCTAssertEqual(
            verify(envelope),
            .rejected(.notThisTreasury)
        )
    }

    func test_anOperationActingOnAThirdAccount_isRefused() throws {
        let envelope = try envelope(
            source: treasuryAccount,
            operations: [
                StellarOperation(sourceAccount: stranger, body: .payment(
                    destination: stranger,
                    asset: .native,
                    amount: StellarAmount(stroops: 1)
                )),
            ]
        )
        XCTAssertEqual(verify(envelope), .rejected(.foreignOperationSource))
    }

    func test_aProposalForAnotherNetwork_isRefused() throws {
        let envelope = try envelope(source: treasuryAccount, operations: [payment()])
        XCTAssertEqual(
            verify(envelope, network: .publicNet),
            .rejected(.wrongNetwork)
        )
    }

    func test_aProposalFromSomeoneOutsideTheGroup_isRefused() throws {
        let envelope = try envelope(source: treasuryAccount, operations: [payment()])
        XCTAssertEqual(
            verify(envelope, proposer: "ffff"),
            .rejected(.proposerNotAMember)
        )
    }

    func test_aProposalForAGroupWithNoTreasury_isRefused() throws {
        let envelope = try envelope(source: treasuryAccount, operations: [payment()])
        XCTAssertEqual(
            verify(envelope, useDefaultTreasury: false),
            .rejected(.noTreasury)
        )
    }

    /// A payment and a signer change in one envelope. Stellar allows
    /// it; one card cannot honestly summarise two asks at two different
    /// thresholds, and the summary is what people read before signing.
    func test_aProposalMixingAPaymentWithAControlChange_isRefused() throws {
        let envelope = try envelope(
            source: treasuryAccount,
            operations: [
                payment(),
                StellarOperation(body: .setOptions(SetOptionsFields(
                    signer: StellarSigner(key: stranger, weight: 1)
                ))),
            ]
        )
        XCTAssertEqual(verify(envelope), .rejected(.unsupportedOperation))
    }

    /// `createAccount` is signed by the founder and the new account
    /// itself, never put to a group — the treasury does not exist yet,
    /// so there is no signer set to ask.
    func test_aCreationTransaction_isNotAcceptedAsAProposal() throws {
        let envelope = try envelope(
            source: treasuryAccount,
            operations: [
                StellarOperation(body: .createAccount(
                    destination: stranger,
                    startingBalance: StellarAmount(stroops: 100)
                )),
            ]
        )
        XCTAssertEqual(verify(envelope), .rejected(.unsupportedOperation))
    }

    // MARK: - Acceptances

    func test_aPayment_isAccepted() throws {
        let envelope = try envelope(source: treasuryAccount, operations: [payment()])
        XCTAssertEqual(verify(envelope), .accepted(.payment))
    }

    func test_aTrustline_isAccepted() throws {
        let envelope = try envelope(
            source: treasuryAccount,
            operations: [StellarOperation(body: .changeTrust(asset: .native, limit: .max))]
        )
        XCTAssertEqual(verify(envelope), .accepted(.trustline))
    }

    func test_addingASigner_isAcceptedAsANomination() throws {
        let envelope = try envelope(
            source: treasuryAccount,
            operations: [
                StellarOperation(body: .setOptions(SetOptionsFields(
                    signer: StellarSigner(key: stranger, weight: 1)
                ))),
            ]
        )
        XCTAssertEqual(verify(envelope), .accepted(.addSigner))
    }

    /// A signer added *and* the thresholds moved, atomically. Allowed
    /// as one proposal because separating them would leave the account
    /// spending the gap in a state nobody chose — a fifth signer on a
    /// medium threshold of 2 quietly makes spending easier.
    func test_addingASignerAndMovingTheThreshold_isOneControlChange() throws {
        let envelope = try envelope(
            source: treasuryAccount,
            operations: [
                StellarOperation(body: .setOptions(SetOptionsFields(
                    signer: StellarSigner(key: stranger, weight: 1)
                ))),
                StellarOperation(body: .setOptions(SetOptionsFields(mediumThreshold: 3))),
            ]
        )
        XCTAssertEqual(verify(envelope), .accepted(.changeControl))
    }

    /// Removal is the same operation with weight zero, and it is a
    /// change of control rather than a nomination.
    func test_removingASigner_isAControlChange() throws {
        let envelope = try envelope(
            source: treasuryAccount,
            operations: [
                StellarOperation(body: .setOptions(SetOptionsFields(
                    signer: StellarSigner(key: stranger, weight: 0)
                ))),
            ]
        )
        XCTAssertEqual(verify(envelope), .accepted(.changeControl))
    }

    // MARK: - Thresholds

    func test_spendingUsesTheMediumThresholdAndControlTheHigh() {
        let thresholds = HorizonThresholds(low: 1, medium: 2, high: 3)
        XCTAssertEqual(TreasuryProposalKind.payment.requiredWeight(from: thresholds), 2)
        XCTAssertEqual(TreasuryProposalKind.trustline.requiredWeight(from: thresholds), 2)
        XCTAssertEqual(TreasuryProposalKind.addSigner.requiredWeight(from: thresholds), 3)
        XCTAssertEqual(TreasuryProposalKind.changeControl.requiredWeight(from: thresholds), 3)
    }

    // MARK: - Standing

    /// A sequence number the account has already passed can never
    /// apply. Reported ahead of expiry, because "another transaction
    /// won" and "you were slow" call for different things.
    func test_aProposalAtAConsumedSequence_isSuperseded() throws {
        let proposal = try makeProposal(sequence: 5)
        let standing = TreasuryProposalVerifier.standing(
            of: proposal,
            account: account(sequence: 5, signers: [], thresholds: .init(low: 1, medium: 1, high: 1)),
            declaredSigners: [],
            now: Date()
        )
        XCTAssertEqual(standing, .superseded)
    }

    func test_supersededIsReportedBeforeExpiry() throws {
        // Both true at once: the honest answer is the permanent one.
        let proposal = try makeProposal(sequence: 5, expiresAt: Date().addingTimeInterval(-60))
        let standing = TreasuryProposalVerifier.standing(
            of: proposal,
            account: account(sequence: 9, signers: [], thresholds: .init(low: 1, medium: 1, high: 1)),
            declaredSigners: [],
            now: Date()
        )
        XCTAssertEqual(standing, .superseded)
    }

    func test_weightIsCountedFromTheLiveSignerList() throws {
        let signerKey = TreasuryTestKeys.key(4)
        let signer = TreasuryTestKeys.account(4)
        var proposal = try makeProposal(sequence: 1)
        try proposal.envelope.sign(with: signerKey, network: .testnet)

        let thresholds = HorizonThresholds(low: 1, medium: 2, high: 2)
        // One signature, threshold two.
        XCTAssertEqual(
            TreasuryProposalVerifier.standing(
                of: proposal,
                account: account(
                    sequence: 0,
                    signers: [StellarSigner(key: signer, weight: 1)],
                    thresholds: thresholds
                ),
                declaredSigners: [signer],
                now: Date()
            ),
            .collecting(weight: 1, required: 2)
        )

        // The same signature, but the chain now gives that key weight 2.
        XCTAssertEqual(
            TreasuryProposalVerifier.standing(
                of: proposal,
                account: account(
                    sequence: 0,
                    signers: [StellarSigner(key: signer, weight: 2)],
                    thresholds: thresholds
                ),
                declaredSigners: [signer],
                now: Date()
            ),
            .ready
        )
    }

    /// A signature from an account nobody declared carries no weight
    /// here, even when the chain would give it weight.
    ///
    /// The first version of this put the signer in neither the declared
    /// list nor the on-chain one — and `HorizonAccount.weight(of:)`
    /// filters by the on-chain list itself, so the answer was zero
    /// whether or not `standing` consulted `declaredSigners` at all.
    /// Deleting the `signers(among:)` filter left it green. The signer
    /// is on-chain at weight 1 now, and only the declaration is
    /// missing, so the filter is the only thing keeping this at zero.
    func test_aSignatureFromAnUndeclaredAccount_addsNoWeight() throws {
        let undeclared = TreasuryTestKeys.account(7)
        let declared = TreasuryTestKeys.account(4)
        var proposal = try makeProposal(sequence: 1)
        try proposal.envelope.sign(with: TreasuryTestKeys.key(7), network: .testnet)

        let standing = TreasuryProposalVerifier.standing(
            of: proposal,
            account: account(
                sequence: 0,
                signers: [
                    StellarSigner(key: declared, weight: 1),
                    // On-chain, and would be counted if the declaration
                    // filter were not there.
                    StellarSigner(key: undeclared, weight: 1),
                ],
                thresholds: .init(low: 1, medium: 1, high: 1)
            ),
            declaredSigners: [declared],
            now: Date()
        )
        XCTAssertEqual(standing, .collecting(weight: 0, required: 1))
    }

    /// The positive half of the PR's headline refusals: a proposal that
    /// simply ran out of time. Only the *ordering* against `superseded`
    /// was pinned, so the expiry arm could have been deleted and only
    /// that test's setup would have noticed.
    func test_aProposalPastItsTimeBound_readsAsExpired() throws {
        let proposal = try makeProposal(
            sequence: 1,
            expiresAt: Date().addingTimeInterval(-60)
        )
        let standing = TreasuryProposalVerifier.standing(
            of: proposal,
            account: account(
                sequence: 0,
                signers: [],
                thresholds: .init(low: 1, medium: 1, high: 1)
            ),
            declaredSigners: [],
            now: Date()
        )
        XCTAssertEqual(standing, .expired)
    }

    // MARK: - Helpers

    private func payment() -> StellarOperation {
        StellarOperation(body: .payment(
            destination: stranger,
            asset: .native,
            amount: StellarAmount(stroops: 1_000)
        ))
    }

    private func envelope(
        source: StellarAccountID,
        operations: [StellarOperation]
    ) throws -> TransactionEnvelope {
        TransactionEnvelope(transaction: try StellarTransaction(
            sourceAccount: source,
            fee: 100,
            sequenceNumber: 2,
            timeBounds: Self.soon,
            operations: operations
        ))
    }

    private func verify(
        _ envelope: TransactionEnvelope,
        network: StellarNetwork = .testnet,
        proposer: String = "aa",
        useDefaultTreasury: Bool = true
    ) -> TreasuryProposalVerifier.Outcome {
        TreasuryProposalVerifier.verify(
            envelope: envelope,
            network: network,
            treasury: useDefaultTreasury ? defaultTreasury : nil,
            proposerBlsPubkeyHex: proposer,
            group: group
        )
    }

    private var defaultTreasury: Treasury {
        Treasury(
            account: treasuryAccount,
            groupID: groupIDHex,
            ownerIdentityID: owner,
            network: .testnet,
            creationTxHash: "hash",
            createdAt: Date()
        )
    }

    private var group: ChatGroup {
        var group = ChatGroup(
            id: groupIDHex,
            ownerIdentityID: owner,
            name: "Test",
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
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: true
        )
        group.memberProfiles = [
            "aa": MemberProfile(
                alias: "Ada",
                inboxPublicKey: Data(repeating: 3, count: 32),
                sendingPubkey: Data(repeating: 4, count: 32)
            ),
        ]
        return group
    }

    private func makeProposal(
        sequence: Int64,
        expiresAt: Date? = nil
    ) throws -> TreasuryProposal {
        let maxTime = expiresAt.map { UInt64($0.timeIntervalSince1970) } ?? 4_000_000_000
        let transaction = try StellarTransaction(
            sourceAccount: treasuryAccount,
            fee: 100,
            sequenceNumber: sequence,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: maxTime),
            operations: [payment()]
        )
        return TreasuryProposal(
            id: UUID(),
            groupID: groupIDHex,
            ownerIdentityID: owner,
            proposerBlsPubkeyHex: "aa",
            treasuryAccount: treasuryAccount,
            network: .testnet,
            kind: .payment,
            envelope: TransactionEnvelope(transaction: transaction),
            createdAt: Date()
        )
    }

    private func account(
        sequence: Int64,
        signers: [StellarSigner],
        thresholds: HorizonThresholds
    ) -> HorizonAccount {
        HorizonAccount(
            accountID: treasuryAccount,
            sequenceNumber: sequence,
            balances: [],
            signers: signers,
            thresholds: thresholds
        )
    }
}

/// Regression tests for the findings in review of #330 and #332.
///
/// Each one is a way an inbound payload could otherwise reach a
/// co-signer's screen carrying more authority than it looked like it
/// had.
final class TreasuryReviewRegressionTests: XCTestCase {

    private let treasuryAccount = TreasuryTestKeys.account(90)
    private static var soon: StellarTimeBounds { TreasuryVerifierTests.soon }
    private let stranger = TreasuryTestKeys.account(91)
    private let owner = IdentityID(UUID())
    private let groupIDHex = String(repeating: "ab", count: 32)

    /// A fee is a real spend that shows up in none of the operation
    /// rows, and the card is built from operations only. `fee =
    /// UInt32.max` on a one-stroop payment is ~429 XLM leaving the
    /// treasury with nothing on screen to account for it.
    func test_anExtravagantFee_isRefused() throws {
        let outcome = TreasuryProposalVerifier.verify(
            envelope: try envelope(fee: .max),
            network: .testnet,
            treasury: treasury,
            proposerBlsPubkeyHex: "aa",
            group: group
        )
        XCTAssertEqual(outcome, .rejected(.excessiveFee))
    }

    /// The worst bug found in review: without a time bound a proposal
    /// never expires, and because it holds the treasury's next sequence
    /// number every honest device then answers `.sequenceContended` for
    /// every later proposal. One message from any member, and the
    /// treasury is unusable for good.
    func test_aProposalWithNoTimeBound_isRefused() throws {
        let outcome = TreasuryProposalVerifier.verify(
            envelope: try envelope(bounds: nil),
            network: .testnet,
            treasury: treasury,
            proposerBlsPubkeyHex: "aa",
            group: group
        )
        XCTAssertEqual(outcome, .rejected(.noExpiry))
    }

    /// A bound in 2096 is the same thing wearing a hat.
    func test_aProposalThatOutlivesTheWindow_isRefused() throws {
        let far = StellarTimeBounds(minTime: 0, maxTime: 4_000_000_000)
        let outcome = TreasuryProposalVerifier.verify(
            envelope: try envelope(bounds: far),
            network: .testnet,
            treasury: treasury,
            proposerBlsPubkeyHex: "aa",
            group: group
        )
        XCTAssertEqual(outcome, .rejected(.expiresTooLate))
    }

    /// An envelope packed with junk signatures verifies cleanly and can
    /// then never be signed by anyone, because `append` refuses past
    /// the protocol's cap — which reaches the co-signer as "signature
    /// did not verify".
    func test_aProposalArrivingFullOfSignatures_isRefused() throws {
        var envelope = try self.envelope(bounds: TreasuryVerifierTests.soon)
        for seed in 1...UInt8(10) {
            let key = try Curve25519.Signing.PrivateKey(
                rawRepresentation: Data(repeating: seed, count: 32)
            )
            try envelope.sign(with: key, network: .testnet)
        }
        let outcome = TreasuryProposalVerifier.verify(
            envelope: envelope,
            network: .testnet,
            treasury: treasury,
            proposerBlsPubkeyHex: "aa",
            group: group
        )
        XCTAssertEqual(outcome, .rejected(.tooManySignatures))
    }

    /// A proposer signing their own proposal before sending it is
    /// ordinary and must still be accepted.
    func test_aProposalCarryingItsProposersOwnSignature_isAccepted() throws {
        var envelope = try self.envelope(bounds: TreasuryVerifierTests.soon)
        try envelope.sign(with: TreasuryTestKeys.key(93), network: .testnet)
        let outcome = TreasuryProposalVerifier.verify(
            envelope: envelope,
            network: .testnet,
            treasury: treasury,
            proposerBlsPubkeyHex: "aa",
            group: group
        )
        XCTAssertEqual(outcome, .accepted(.payment))
    }

    /// A busy ledger legitimately costs more than a quiet one, so the
    /// bound is a ceiling rather than an exact match.
    func test_anOrdinaryAndAModeratelySurgedFee_areBothAccepted() throws {
        for fee in [UInt32(100), 1_000, TreasuryProposalVerifier.maxFeePerOperation] {
            XCTAssertEqual(
                TreasuryProposalVerifier.verify(
                    envelope: try envelope(fee: fee),
                    network: .testnet,
                    treasury: treasury,
                    proposerBlsPubkeyHex: "aa",
                    group: group
                ),
                .accepted(.payment),
                "fee \(fee) should be allowed"
            )
        }
    }

    /// The fee also has to be visible, so the two defences don't depend
    /// on each other — but not on every card, or people learn to skip
    /// the row.
    func test_theFeeIsShownOnlyWhenItIsAboveTheOrdinaryRate() throws {
        let ordinary = TreasuryProposalDescription(try proposal(fee: 100))
        XCTAssertFalse(ordinary.lines.contains { $0.label == "Network fee" })

        let surged = TreasuryProposalDescription(try proposal(fee: 9_000))
        let line = try XCTUnwrap(surged.lines.first { $0.label == "Network fee" })
        XCTAssertTrue(line.isPrincipal, "a fee this far above the rate should stand out")
    }

    // MARK: - Helpers

    private func envelope(
        fee: UInt32 = 100,
        bounds: StellarTimeBounds? = TreasuryVerifierTests.soon
    ) throws -> TransactionEnvelope {
        TransactionEnvelope(transaction: try StellarTransaction(
            sourceAccount: treasuryAccount,
            fee: fee,
            sequenceNumber: 2,
            timeBounds: bounds,
            operations: [
                StellarOperation(body: .payment(
                    destination: stranger,
                    asset: .native,
                    amount: StellarAmount(stroops: 1)
                )),
            ]
        ))
    }

    private func proposal(fee: UInt32) throws -> TreasuryProposal {
        TreasuryProposal(
            id: UUID(),
            groupID: groupIDHex,
            ownerIdentityID: owner,
            proposerBlsPubkeyHex: "aa",
            treasuryAccount: treasuryAccount,
            network: .testnet,
            kind: .payment,
            envelope: try envelope(fee: fee),
            createdAt: Date()
        )
    }

    private var treasury: Treasury {
        Treasury(
            account: treasuryAccount,
            groupID: groupIDHex,
            ownerIdentityID: owner,
            network: .testnet,
            creationTxHash: "hash",
            createdAt: Date()
        )
    }

    private var group: ChatGroup {
        var group = ChatGroup(
            id: groupIDHex,
            ownerIdentityID: owner,
            name: "Test",
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
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: true
        )
        group.memberProfiles = [
            "aa": MemberProfile(
                alias: "Ada",
                inboxPublicKey: Data(repeating: 3, count: 32),
                sendingPubkey: Data(repeating: 4, count: 32)
            ),
        ]
        return group
    }
}
