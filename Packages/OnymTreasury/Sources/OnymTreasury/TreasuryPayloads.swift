import Foundation
import OnymStellar

/// The four treasury payloads that travel between members' inboxes,
/// sealed per recipient on the same path as `ChatMessagePayload`.
///
/// ## Wire-shape disjointness
///
/// `IncomingMessageDispatcher` routes by trying `try? decode` against
/// each payload type in a fixed order, so a new type must be impossible
/// to confuse with an existing one. Every type here carries a required
/// `treasury` key whose value is its own discriminator — no other inbox
/// payload has that key, and none of these decodes as another because
/// the discriminator differs. Decoding is written by hand for exactly
/// this reason: a synthesized decoder would happily ignore the
/// discriminator it was handed.
///
/// ## What the signatures are for
///
/// A sealed envelope's Ed25519 signature covers the ephemeral key, not
/// the plaintext, so it authenticates the *sender of the envelope* and
/// nothing about the contents. The dispatcher uses that to attribute
/// the message; where a claim has to outlive the delivery — a
/// declaration someone may be asked about later — the payload carries
/// its own detached signature over canonical bytes.
///
/// `TreasurySignaturePayload` is the exception that needs no such
/// signature, because what it carries verifies itself: a Stellar
/// signature either checks out against the recipient's own
/// transaction hash or it does not.
enum TreasuryPayloadKind {
    static let declaration = "signer_declaration"
    static let anchor = "anchor"
    static let proposal = "proposal"
    static let signature = "signature"
}

private enum SharedKeys: String, CodingKey {
    case treasury
    case version
    case groupID = "group_id"
    case sentAtMillis = "sent_at_millis"
}

/// Decode helper: reads and checks the discriminator before anything
/// else, so a payload of a different kind fails immediately rather than
/// part-way through.
private func expectKind(
    _ expected: String,
    in container: KeyedDecodingContainer<SharedKeys>
) throws {
    let kind = try container.decode(String.self, forKey: .treasury)
    guard kind == expected else {
        throw DecodingError.dataCorruptedError(
            forKey: .treasury,
            in: container,
            debugDescription: "expected treasury payload '\(expected)', got '\(kind)'"
        )
    }
}

// MARK: - Declaration

/// "This is the Stellar account I want to co-sign with in this group."
///
/// Broadcast to every member rather than only the founder: any member
/// can then check any other member's declaration for themselves, which
/// is the same property `MemberProfile`'s rules agreement has. The
/// founder who assembles the signer set is not a required witness.
public struct TreasurySignerDeclarationPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let groupID: Data
    /// Lowercase BLS pubkey hex of the declarer.
    public let declarerBlsPubkeyHex: String
    public let signerAccountID: String
    public let source: TreasurySignerSource
    public let sentAtMillis: Int64
    /// 64-byte detached Ed25519 signature over
    /// `TreasurySignerDeclaration.statement(…)`.
    public let signature: Data

    public init(
        version: Int = 1,
        groupID: Data,
        declarerBlsPubkeyHex: String,
        signerAccountID: String,
        source: TreasurySignerSource,
        sentAtMillis: Int64,
        signature: Data
    ) {
        self.version = version
        self.groupID = groupID
        self.declarerBlsPubkeyHex = declarerBlsPubkeyHex.lowercased()
        self.signerAccountID = signerAccountID
        self.source = source
        self.sentAtMillis = sentAtMillis
        self.signature = signature
    }

    private enum Keys: String, CodingKey {
        case treasury, version, source, signature
        case groupID = "group_id"
        case declarerBlsPubkeyHex = "declarer_bls_pubkey_hex"
        case signerAccountID = "signer_account_id"
        case sentAtMillis = "sent_at_millis"
    }

    public init(from decoder: Decoder) throws {
        try expectKind(
            TreasuryPayloadKind.declaration,
            in: decoder.container(keyedBy: SharedKeys.self)
        )
        let c = try decoder.container(keyedBy: Keys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.groupID = try c.decode(Data.self, forKey: .groupID)
        self.declarerBlsPubkeyHex = try c
            .decode(String.self, forKey: .declarerBlsPubkeyHex).lowercased()
        self.signerAccountID = try c.decode(String.self, forKey: .signerAccountID)
        self.source = try c.decode(TreasurySignerSource.self, forKey: .source)
        self.sentAtMillis = try c.decode(Int64.self, forKey: .sentAtMillis)
        self.signature = try c.decode(Data.self, forKey: .signature)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(TreasuryPayloadKind.declaration, forKey: .treasury)
        try c.encode(version, forKey: .version)
        try c.encode(groupID, forKey: .groupID)
        try c.encode(declarerBlsPubkeyHex, forKey: .declarerBlsPubkeyHex)
        try c.encode(signerAccountID, forKey: .signerAccountID)
        try c.encode(source, forKey: .source)
        try c.encode(sentAtMillis, forKey: .sentAtMillis)
        try c.encode(signature, forKey: .signature)
    }
}

// MARK: - Anchor

/// "This group's treasury is this account, created by this transaction."
///
/// Sent by the founder once creation has applied. Receivers check the
/// envelope's Ed25519 signer against `ChatGroup.adminEd25519PubkeyHex`
/// — the same admin gate `GroupAvatarPayload` uses — so a member cannot
/// point the group at an account they control.
///
/// The claim is also independently checkable, which matters more than
/// the gate: `creationTxHash` names a transaction on a public ledger,
/// and anyone can look up whether that transaction really created this
/// account with this signer set.
public struct TreasuryAnchorPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let groupID: Data
    public let treasuryAccountID: String
    public let networkPassphrase: String
    public let creationTxHash: String
    public let sentAtMillis: Int64

    public init(
        version: Int = 1,
        groupID: Data,
        treasuryAccountID: String,
        networkPassphrase: String,
        creationTxHash: String,
        sentAtMillis: Int64
    ) {
        self.version = version
        self.groupID = groupID
        self.treasuryAccountID = treasuryAccountID
        self.networkPassphrase = networkPassphrase
        self.creationTxHash = creationTxHash
        self.sentAtMillis = sentAtMillis
    }

    private enum Keys: String, CodingKey {
        case treasury, version
        case groupID = "group_id"
        case treasuryAccountID = "treasury_account_id"
        case networkPassphrase = "network_passphrase"
        case creationTxHash = "creation_tx_hash"
        case sentAtMillis = "sent_at_millis"
    }

    public init(from decoder: Decoder) throws {
        try expectKind(
            TreasuryPayloadKind.anchor,
            in: decoder.container(keyedBy: SharedKeys.self)
        )
        let c = try decoder.container(keyedBy: Keys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.groupID = try c.decode(Data.self, forKey: .groupID)
        self.treasuryAccountID = try c.decode(String.self, forKey: .treasuryAccountID)
        self.networkPassphrase = try c.decode(String.self, forKey: .networkPassphrase)
        self.creationTxHash = try c.decode(String.self, forKey: .creationTxHash)
        self.sentAtMillis = try c.decode(Int64.self, forKey: .sentAtMillis)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(TreasuryPayloadKind.anchor, forKey: .treasury)
        try c.encode(version, forKey: .version)
        try c.encode(groupID, forKey: .groupID)
        try c.encode(treasuryAccountID, forKey: .treasuryAccountID)
        try c.encode(networkPassphrase, forKey: .networkPassphrase)
        try c.encode(creationTxHash, forKey: .creationTxHash)
        try c.encode(sentAtMillis, forKey: .sentAtMillis)
    }
}

// MARK: - Proposal

/// An unsigned transaction put to the group.
///
/// Deliberately carries **no description** of what it does — no amount,
/// no recipient, no summary. Every receiving device decodes `xdr` and
/// renders from the operations it finds. A description field would be a
/// second, sender-controlled account of the same transaction, and the
/// one people read before signing.
public struct TreasuryProposalPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let groupID: Data
    public let proposalID: UUID
    /// Lowercase BLS pubkey hex of the proposer. Cross-checked against
    /// the envelope's verified sender, never trusted on its own.
    public let proposerBlsPubkeyHex: String
    /// Base64 `TransactionEnvelope` XDR, unsigned or carrying the
    /// proposer's own signature.
    public let xdr: String
    public let networkPassphrase: String
    public let sentAtMillis: Int64

    public init(
        version: Int = 1,
        groupID: Data,
        proposalID: UUID,
        proposerBlsPubkeyHex: String,
        xdr: String,
        networkPassphrase: String,
        sentAtMillis: Int64
    ) {
        self.version = version
        self.groupID = groupID
        self.proposalID = proposalID
        self.proposerBlsPubkeyHex = proposerBlsPubkeyHex.lowercased()
        self.xdr = xdr
        self.networkPassphrase = networkPassphrase
        self.sentAtMillis = sentAtMillis
    }

    private enum Keys: String, CodingKey {
        case treasury, version, xdr
        case groupID = "group_id"
        case proposalID = "proposal_id"
        case proposerBlsPubkeyHex = "proposer_bls_pubkey_hex"
        case networkPassphrase = "network_passphrase"
        case sentAtMillis = "sent_at_millis"
    }

    public init(from decoder: Decoder) throws {
        try expectKind(
            TreasuryPayloadKind.proposal,
            in: decoder.container(keyedBy: SharedKeys.self)
        )
        let c = try decoder.container(keyedBy: Keys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.groupID = try c.decode(Data.self, forKey: .groupID)
        self.proposalID = try c.decode(UUID.self, forKey: .proposalID)
        self.proposerBlsPubkeyHex = try c
            .decode(String.self, forKey: .proposerBlsPubkeyHex).lowercased()
        self.xdr = try c.decode(String.self, forKey: .xdr)
        self.networkPassphrase = try c.decode(String.self, forKey: .networkPassphrase)
        self.sentAtMillis = try c.decode(Int64.self, forKey: .sentAtMillis)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(TreasuryPayloadKind.proposal, forKey: .treasury)
        try c.encode(version, forKey: .version)
        try c.encode(groupID, forKey: .groupID)
        try c.encode(proposalID, forKey: .proposalID)
        try c.encode(proposerBlsPubkeyHex, forKey: .proposerBlsPubkeyHex)
        try c.encode(xdr, forKey: .xdr)
        try c.encode(networkPassphrase, forKey: .networkPassphrase)
        try c.encode(sentAtMillis, forKey: .sentAtMillis)
    }
}

// MARK: - Signature

/// One co-signer's signature on a proposal.
///
/// The only payload here that needs no signature of its own: the
/// recipient rebuilds the transaction hash from the proposal it already
/// holds and checks these 64 bytes against `signerAccountID`. A forged
/// or misattributed one fails that check, so there is nothing for an
/// extra signature to add.
public struct TreasurySignaturePayload: Codable, Equatable, Sendable {
    public let version: Int
    public let groupID: Data
    public let proposalID: UUID
    public let signerAccountID: String
    /// 64-byte Ed25519 signature over the proposal's transaction hash.
    public let signature: Data
    public let sentAtMillis: Int64

    public init(
        version: Int = 1,
        groupID: Data,
        proposalID: UUID,
        signerAccountID: String,
        signature: Data,
        sentAtMillis: Int64
    ) {
        self.version = version
        self.groupID = groupID
        self.proposalID = proposalID
        self.signerAccountID = signerAccountID
        self.signature = signature
        self.sentAtMillis = sentAtMillis
    }

    private enum Keys: String, CodingKey {
        case treasury, version, signature
        case groupID = "group_id"
        case proposalID = "proposal_id"
        case signerAccountID = "signer_account_id"
        case sentAtMillis = "sent_at_millis"
    }

    public init(from decoder: Decoder) throws {
        try expectKind(
            TreasuryPayloadKind.signature,
            in: decoder.container(keyedBy: SharedKeys.self)
        )
        let c = try decoder.container(keyedBy: Keys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.groupID = try c.decode(Data.self, forKey: .groupID)
        self.proposalID = try c.decode(UUID.self, forKey: .proposalID)
        self.signerAccountID = try c.decode(String.self, forKey: .signerAccountID)
        self.signature = try c.decode(Data.self, forKey: .signature)
        self.sentAtMillis = try c.decode(Int64.self, forKey: .sentAtMillis)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(TreasuryPayloadKind.signature, forKey: .treasury)
        try c.encode(version, forKey: .version)
        try c.encode(groupID, forKey: .groupID)
        try c.encode(proposalID, forKey: .proposalID)
        try c.encode(signerAccountID, forKey: .signerAccountID)
        try c.encode(signature, forKey: .signature)
        try c.encode(sentAtMillis, forKey: .sentAtMillis)
    }
}
