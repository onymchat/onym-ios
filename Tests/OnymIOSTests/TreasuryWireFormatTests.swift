import XCTest
@testable import OnymIOS
import OnymChatsCore
import OnymGroup
import OnymStellar
import OnymTreasury

/// Wire-format pins for the four treasury payloads, in the style of
/// `ChatMessagePayloadTests`. Field spelling and the `treasury`
/// discriminator are a cross-platform contract — Android has to write
/// the same keys — so they are locked here rather than left to whatever
/// the Swift encoder happens to emit.
///
/// The disjointness suite below is the one that matters most.
/// `IncomingMessageDispatcher` routes by trying `try? decode` against
/// each payload type in a fixed order, so a type that can decode as
/// another one silently steals its messages.
final class TreasuryWireFormatTests: XCTestCase {

    private let groupID = Data(repeating: 0xAB, count: 32)
    private let proposalID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - Field spelling

    func test_declaration_pinsItsWireKeys() throws {
        let payload = TreasurySignerDeclarationPayload(
            groupID: groupID,
            declarerBlsPubkeyHex: "AABB",
            signerAccountID: TreasuryTestKeys.account(1).accountID,
            source: .external,
            sentAtMillis: 1_700_000_000_000,
            signature: Data(repeating: 7, count: 64)
        )
        let json = try object(payload)
        XCTAssertEqual(json["treasury"] as? String, "signer_declaration")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["source"] as? String, "external")
        XCTAssertNotNil(json["group_id"])
        XCTAssertNotNil(json["declarer_bls_pubkey_hex"])
        XCTAssertNotNil(json["signer_account_id"])
        XCTAssertNotNil(json["sent_at_millis"])
        XCTAssertNotNil(json["signature"])
        // Lowercased on the way in — the roster is keyed lowercase.
        XCTAssertEqual(payload.declarerBlsPubkeyHex, "aabb")
    }

    func test_anchor_pinsItsWireKeys() throws {
        let json = try object(TreasuryAnchorPayload(
            groupID: groupID,
            treasuryAccountID: TreasuryTestKeys.account(2).accountID,
            networkPassphrase: StellarNetwork.testnet.passphrase,
            creationTxHash: "abc123",
            sentAtMillis: 1
        ))
        XCTAssertEqual(json["treasury"] as? String, "anchor")
        XCTAssertNotNil(json["treasury_account_id"])
        XCTAssertNotNil(json["network_passphrase"])
        XCTAssertNotNil(json["creation_tx_hash"])
    }

    func test_proposal_pinsItsWireKeys() throws {
        let json = try object(TreasuryProposalPayload(
            groupID: groupID,
            proposalID: proposalID,
            proposerBlsPubkeyHex: "ff",
            xdr: "AAAA",
            networkPassphrase: StellarNetwork.testnet.passphrase,
            sentAtMillis: 1
        ))
        XCTAssertEqual(json["treasury"] as? String, "proposal")
        XCTAssertNotNil(json["proposal_id"])
        XCTAssertNotNil(json["proposer_bls_pubkey_hex"])
        XCTAssertNotNil(json["xdr"])
    }

    /// The proposal payload carries no description of what the
    /// transaction does, and must never grow one: every receiver
    /// decodes the XDR itself, and a second sender-controlled account
    /// of the same transaction is the one people would read.
    func test_proposal_carriesNoSenderWrittenDescription() throws {
        let json = try object(TreasuryProposalPayload(
            groupID: groupID,
            proposalID: proposalID,
            proposerBlsPubkeyHex: "ff",
            xdr: "AAAA",
            networkPassphrase: StellarNetwork.testnet.passphrase,
            sentAtMillis: 1
        ))
        for forbidden in ["memo", "description", "summary", "title", "amount", "destination"] {
            XCTAssertNil(json[forbidden], "'\(forbidden)' must not be on the wire")
        }
    }

    func test_signature_pinsItsWireKeys() throws {
        let json = try object(TreasurySignaturePayload(
            groupID: groupID,
            proposalID: proposalID,
            signerAccountID: TreasuryTestKeys.account(3).accountID,
            signature: Data(repeating: 9, count: 64),
            sentAtMillis: 1
        ))
        XCTAssertEqual(json["treasury"] as? String, "signature")
        XCTAssertNotNil(json["signer_account_id"])
    }

    func test_everyPayload_roundTrips() throws {
        let declaration = TreasurySignerDeclarationPayload(
            groupID: groupID,
            declarerBlsPubkeyHex: "aabb",
            signerAccountID: TreasuryTestKeys.account(1).accountID,
            source: .onym,
            sentAtMillis: 5,
            signature: Data(repeating: 7, count: 64)
        )
        XCTAssertEqual(try roundTrip(declaration), declaration)

        let anchor = TreasuryAnchorPayload(
            groupID: groupID,
            treasuryAccountID: TreasuryTestKeys.account(2).accountID,
            networkPassphrase: StellarNetwork.publicNet.passphrase,
            creationTxHash: "hash",
            sentAtMillis: 5
        )
        XCTAssertEqual(try roundTrip(anchor), anchor)

        let proposal = TreasuryProposalPayload(
            groupID: groupID,
            proposalID: proposalID,
            proposerBlsPubkeyHex: "cc",
            xdr: "AAAAAg==",
            networkPassphrase: StellarNetwork.testnet.passphrase,
            sentAtMillis: 5
        )
        XCTAssertEqual(try roundTrip(proposal), proposal)

        let signature = TreasurySignaturePayload(
            groupID: groupID,
            proposalID: proposalID,
            signerAccountID: TreasuryTestKeys.account(3).accountID,
            signature: Data(repeating: 9, count: 64),
            sentAtMillis: 5
        )
        XCTAssertEqual(try roundTrip(signature), signature)
    }

    // MARK: - Disjointness

    /// No treasury payload decodes as another. They share a `treasury`
    /// key by design, so this is the check that their discriminators
    /// are actually enforced rather than merely present.
    func test_noTreasuryPayload_decodesAsAnother() throws {
        let bytes = try allTreasuryPayloadBytes()
        for (name, data) in bytes {
            for (otherName, decode) in Self.treasuryDecoders where otherName != name {
                XCTAssertFalse(
                    decode(data),
                    "\(name) wrongly decoded as \(otherName)"
                )
            }
        }
    }

    /// No treasury payload decodes as any payload that already travels
    /// on this inbox — the dispatcher would route it to the wrong
    /// handler.
    func test_noTreasuryPayload_decodesAsAnExistingInboxPayload() throws {
        for (name, data) in try allTreasuryPayloadBytes() {
            XCTAssertNil(
                try? JSONDecoder().decode(ChatMessagePayload.self, from: data),
                "\(name) decoded as a chat message"
            )
            XCTAssertNil(
                try? JSONDecoder().decode(ChatReceiptPayload.self, from: data),
                "\(name) decoded as a receipt"
            )
            XCTAssertNil(
                try? JSONDecoder().decode(GroupAvatarPayload.self, from: data),
                "\(name) decoded as an avatar update"
            )
            XCTAssertNil(
                try? JSONDecoder().decode(GroupNamePayload.self, from: data),
                "\(name) decoded as a name update"
            )
            XCTAssertNil(
                try? JSONDecoder().decode(MemberAnnouncementPayload.self, from: data),
                "\(name) decoded as a member announcement"
            )
        }
    }

    /// And the reverse: an existing payload must not decode as a
    /// treasury one, which would take a chat message out of the thread
    /// and into the treasury handler.
    func test_noExistingInboxPayload_decodesAsATreasuryPayload() throws {
        let chat = try JSONEncoder().encode(ChatMessagePayload(
            version: 1,
            messageID: UUID(),
            groupID: groupID,
            senderBlsPubkeyHex: "aa",
            sentAtMillis: 1,
            replyToMessageID: nil,
            variant: .tyranny(body: "hello")
        ))
        let avatar = try JSONEncoder().encode(GroupAvatarPayload(
            version: 1,
            groupID: groupID,
            senderBlsPubkeyHex: "aa",
            sentAtMillis: 1,
            avatar: nil
        ))
        for (name, data) in [("chat message", chat), ("avatar", avatar)] {
            for (treasuryName, decode) in Self.treasuryDecoders {
                XCTAssertFalse(decode(data), "\(name) decoded as \(treasuryName)")
            }
        }
    }

    /// A payload whose `treasury` discriminator names a different kind
    /// is refused rather than read for its other fields — the check
    /// that makes the disjointness above hold.
    func test_aMismatchedDiscriminator_isRefused() throws {
        var json = try object(TreasuryAnchorPayload(
            groupID: groupID,
            treasuryAccountID: TreasuryTestKeys.account(2).accountID,
            networkPassphrase: StellarNetwork.testnet.passphrase,
            creationTxHash: "hash",
            sentAtMillis: 1
        ))
        json["treasury"] = "proposal"
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try? JSONDecoder().decode(TreasuryAnchorPayload.self, from: data))
        XCTAssertNil(try? JSONDecoder().decode(TreasuryProposalPayload.self, from: data))
    }

    // MARK: - Helpers

    private static let treasuryDecoders: [(String, (Data) -> Bool)] = [
        ("declaration", { (try? JSONDecoder().decode(
            TreasurySignerDeclarationPayload.self, from: $0)) != nil }),
        ("anchor", { (try? JSONDecoder().decode(
            TreasuryAnchorPayload.self, from: $0)) != nil }),
        ("proposal", { (try? JSONDecoder().decode(
            TreasuryProposalPayload.self, from: $0)) != nil }),
        ("signature", { (try? JSONDecoder().decode(
            TreasurySignaturePayload.self, from: $0)) != nil }),
    ]

    private func allTreasuryPayloadBytes() throws -> [(String, Data)] {
        [
            ("declaration", try JSONEncoder().encode(TreasurySignerDeclarationPayload(
                groupID: groupID,
                declarerBlsPubkeyHex: "aa",
                signerAccountID: TreasuryTestKeys.account(1).accountID,
                source: .onym,
                sentAtMillis: 1,
                signature: Data(repeating: 1, count: 64)
            ))),
            ("anchor", try JSONEncoder().encode(TreasuryAnchorPayload(
                groupID: groupID,
                treasuryAccountID: TreasuryTestKeys.account(2).accountID,
                networkPassphrase: StellarNetwork.testnet.passphrase,
                creationTxHash: "hash",
                sentAtMillis: 1
            ))),
            ("proposal", try JSONEncoder().encode(TreasuryProposalPayload(
                groupID: groupID,
                proposalID: proposalID,
                proposerBlsPubkeyHex: "aa",
                xdr: "AAAA",
                networkPassphrase: StellarNetwork.testnet.passphrase,
                sentAtMillis: 1
            ))),
            ("signature", try JSONEncoder().encode(TreasurySignaturePayload(
                groupID: groupID,
                proposalID: proposalID,
                signerAccountID: TreasuryTestKeys.account(3).accountID,
                signature: Data(repeating: 2, count: 64),
                sentAtMillis: 1
            ))),
        ]
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
    }
}
