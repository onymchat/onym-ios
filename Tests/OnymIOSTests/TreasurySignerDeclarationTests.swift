import CryptoKit
import XCTest
@testable import OnymIOS
import OnymIdentity
import OnymStellar
import OnymTreasury

/// The signed statement that says which Stellar account is whose.
///
/// Modelled on `GroupRulesTests`: the statement's byte shape is a
/// cross-platform contract, and each component of it is there to stop a
/// specific substitution.
final class TreasurySignerDeclarationTests: XCTestCase {

    private let groupA = Data(repeating: 0xA1, count: 32)
    private let groupB = Data(repeating: 0xB2, count: 32)
    private let declarerKey = TreasuryTestKeys.key(11)
    private var declarerPub: Data { Data(declarerKey.publicKey.rawRepresentation) }
    private let account = TreasuryTestKeys.account(12)

    // MARK: - Byte shape

    func test_theStatement_isTheDomainThenThreeFixedLengthFields() {
        let statement = TreasurySignerDeclaration.statement(
            groupID: groupA,
            signerAccount: account,
            declarerSendingPublicKey: declarerPub
        )
        let domain = Data("onym-treasury-signer-v1".utf8)
        XCTAssertEqual(statement.prefix(domain.count), domain)
        // Every field after the domain is fixed-length, which is what
        // makes the concatenation unambiguous without length prefixes.
        XCTAssertEqual(statement.count, domain.count + 32 + 32 + 32)
        XCTAssertEqual(
            Data(statement.dropFirst(domain.count).prefix(32)),
            groupA
        )
        XCTAssertEqual(
            Data(statement.dropFirst(domain.count + 32).prefix(32)),
            account.publicKey
        )
        XCTAssertEqual(Data(statement.suffix(32)), declarerPub)
    }

    // MARK: - What it binds

    func test_aGenuineDeclaration_verifies() throws {
        XCTAssertTrue(TreasurySignerDeclaration.isDeclaration(
            signature: try sign(group: groupA, account: account),
            signerAccount: account,
            groupID: groupA,
            declarerSendingPublicKey: declarerPub
        ))
    }

    /// Without the group id inside the signed bytes, a declaration
    /// collected in a group of friends could be replayed into one
    /// holding real money.
    func test_aDeclarationFromAnotherGroup_doesNotVerifyHere() throws {
        XCTAssertFalse(TreasurySignerDeclaration.isDeclaration(
            signature: try sign(group: groupB, account: account),
            signerAccount: account,
            groupID: groupA,
            declarerSendingPublicKey: declarerPub
        ))
    }

    /// The account is what is being claimed, so a signature cannot be
    /// moved onto a different one.
    func test_aSignatureCannotBeMovedToAnotherAccount() throws {
        XCTAssertFalse(TreasurySignerDeclaration.isDeclaration(
            signature: try sign(group: groupA, account: account),
            signerAccount: TreasuryTestKeys.account(13),
            groupID: groupA,
            declarerSendingPublicKey: declarerPub
        ))
    }

    /// The declarer is named inside the signed bytes, so a declaration
    /// cannot be re-attributed to another member.
    func test_aDeclarationCannotBeReattributedToAnotherMember() throws {
        XCTAssertFalse(TreasurySignerDeclaration.isDeclaration(
            signature: try sign(group: groupA, account: account),
            signerAccount: account,
            groupID: groupA,
            declarerSendingPublicKey: Data(
                TreasuryTestKeys.key(14).publicKey.rawRepresentation
            )
        ))
    }

    func test_malformedBytes_areNotAnAgreement() {
        for signature in [Data(), Data(repeating: 0, count: 63), Data(repeating: 0, count: 65)] {
            XCTAssertFalse(TreasurySignerDeclaration.isDeclaration(
                signature: signature,
                signerAccount: account,
                groupID: groupA,
                declarerSendingPublicKey: declarerPub
            ))
        }
        XCTAssertFalse(TreasurySignerDeclaration.isDeclaration(
            signature: Data(repeating: 0, count: 64),
            signerAccount: account,
            groupID: groupA,
            declarerSendingPublicKey: Data(repeating: 0, count: 31)
        ))
    }

    // MARK: - Standing

    func test_standingIsRederivedFromTheStoredSignature() throws {
        let record = try makeRecord(signature: try sign(group: groupA, account: account))
        XCTAssertEqual(record.standing(groupID: groupA), .declaredOnym)
        // A record whose signature doesn't check out reports that,
        // rather than the source it claims.
        let bogus = try makeRecord(signature: Data(repeating: 0, count: 64))
        XCTAssertEqual(bogus.standing(groupID: groupA), .doesNotVerify)
    }

    /// An externally-held account is unproven until it signs something.
    /// The distinction is the honest one: an Onym identity key cannot
    /// speak for a Stellar account it does not hold.
    func test_anExternalAccount_isUnprovenUntilItSigns() throws {
        var record = try makeRecord(
            signature: try sign(group: groupA, account: account),
            source: .external
        )
        XCTAssertEqual(record.standing(groupID: groupA), .declaredExternalUnproven)
        record.provenAt = Date()
        XCTAssertEqual(record.standing(groupID: groupA), .declaredExternalProven)
    }

    /// Unproven is still nominatable. Refusing it would make the
    /// feature useless for exactly the people it exists for, who by
    /// definition have not signed anything yet — the risk it carries is
    /// deadlock, not theft, and the creation screen names it.
    func test_anUnprovenExternalAccount_canStillBeNominated() {
        XCTAssertTrue(TreasurySignerStanding.declaredExternalUnproven.canBeNominated)
        XCTAssertTrue(TreasurySignerStanding.declaredOnym.canBeNominated)
        XCTAssertTrue(TreasurySignerStanding.declaredExternalProven.canBeNominated)
        XCTAssertFalse(TreasurySignerStanding.notDeclared.canBeNominated)
        XCTAssertFalse(TreasurySignerStanding.doesNotVerify.canBeNominated)
    }

    // MARK: - Helpers

    private func sign(group: Data, account: StellarAccountID) throws -> Data {
        try declarerKey.signature(for: TreasurySignerDeclaration.statement(
            groupID: group,
            signerAccount: account,
            declarerSendingPublicKey: declarerPub
        ))
    }

    private func makeRecord(
        signature: Data,
        source: TreasurySignerSource = .onym
    ) throws -> TreasurySignerDeclarationRecord {
        TreasurySignerDeclarationRecord(
            groupID: String(repeating: "a1", count: 32),
            ownerIdentityID: IdentityID(UUID()),
            memberBlsPubkeyHex: "aa",
            account: account,
            source: source,
            signature: signature,
            declarerSendingPublicKey: declarerPub,
            declaredAt: Date()
        )
    }
}
