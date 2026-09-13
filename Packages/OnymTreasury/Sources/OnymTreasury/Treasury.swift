import Foundation
import OnymIdentity
import OnymStellar

/// The Stellar account a chat thread owns.
///
/// One per group at most, and optional — `MAY have a stellar account
/// associated` is the whole premise, so every surface has to render a
/// group that has none.
///
/// ## Who controls it
///
/// Nobody alone. The account is created with its master key weight set
/// to zero in the same transaction that funds it and installs the
/// co-signers, so from the moment it exists the only way it acts is a
/// quorum of the signer set. The founder is not an exception: after
/// creation they hold no more power over it than any other co-signer,
/// and adding one is itself a proposal at the high threshold.
///
/// That is a deliberate trade. It removes "the founder drained it" as a
/// possibility and introduces "enough co-signers lost their keys" as a
/// permanent one. The creation screen states both.
public struct Treasury: Equatable, Sendable, Identifiable {
    /// The treasury's own account. Also the row's identity — a group has
    /// at most one, and the account is what every proposal names.
    public let account: StellarAccountID
    /// 64-char hex of the parent `ChatGroup.id`. Plain on disk so
    /// lookups are a single predicate, matching `ChatMessage`.
    public let groupID: String
    /// Identity that owns this row, inherited from the group at write
    /// time so removing an identity cascades.
    public let ownerIdentityID: IdentityID
    public let network: StellarNetwork
    /// Hash of the transaction that created it, so anyone can look the
    /// whole arrangement up on a block explorer rather than taking this
    /// app's word for it.
    public let creationTxHash: String
    public let createdAt: Date

    /// Last signer set and thresholds read from the chain, kept only so
    /// the screen has something to draw before the network answers.
    ///
    /// **Never** the basis for deciding whether a proposal has enough
    /// weight. That question is settled against a fresh read, because
    /// the signer set is exactly what a `setOptions` proposal changes —
    /// and a stale snapshot would say "ready" for a quorum that no
    /// longer exists.
    public var lastKnownSigners: [StellarSigner]
    public var lastKnownThresholds: HorizonThresholds?
    public var lastRefreshedAt: Date?

    public var id: String { account.accountID }

    public init(
        account: StellarAccountID,
        groupID: String,
        ownerIdentityID: IdentityID,
        network: StellarNetwork,
        creationTxHash: String,
        createdAt: Date,
        lastKnownSigners: [StellarSigner] = [],
        lastKnownThresholds: HorizonThresholds? = nil,
        lastRefreshedAt: Date? = nil
    ) {
        self.account = account
        self.groupID = groupID
        self.ownerIdentityID = ownerIdentityID
        self.network = network
        self.creationTxHash = creationTxHash
        self.createdAt = createdAt
        self.lastKnownSigners = lastKnownSigners
        self.lastKnownThresholds = lastKnownThresholds
        self.lastRefreshedAt = lastRefreshedAt
    }
}

/// One member's declared co-signer account, as this device holds it.
public struct TreasurySignerDeclarationRecord: Equatable, Sendable {
    public let groupID: String
    public let ownerIdentityID: IdentityID
    /// Lowercase BLS pubkey hex of the member who declared it — the same
    /// keying as `ChatGroup.memberProfiles`.
    public let memberBlsPubkeyHex: String
    public let account: StellarAccountID
    public let source: TreasurySignerSource
    /// The declarer's 64-byte detached signature over
    /// `TreasurySignerDeclaration.statement(…)`. Retained rather than
    /// reduced to a boolean so the claim can be re-checked, and shown to
    /// someone who does not trust this app.
    public let signature: Data
    /// The declarer's Ed25519 sending key — the bytes the signature is
    /// checked against. Stored beside it for the same reason
    /// `MemberProfile` keeps `rulesText`: a signature is evidence only
    /// if what it was checked against can be produced again.
    public let declarerSendingPublicKey: Data
    public let declaredAt: Date
    /// Set once this account has produced a valid signature over one of
    /// the group's treasury transactions — the only thing that
    /// demonstrates control of an externally-held account.
    public var provenAt: Date?

    public init(
        groupID: String,
        ownerIdentityID: IdentityID,
        memberBlsPubkeyHex: String,
        account: StellarAccountID,
        source: TreasurySignerSource,
        signature: Data,
        declarerSendingPublicKey: Data,
        declaredAt: Date,
        provenAt: Date? = nil
    ) {
        self.groupID = groupID
        self.ownerIdentityID = ownerIdentityID
        self.memberBlsPubkeyHex = memberBlsPubkeyHex.lowercased()
        self.account = account
        self.source = source
        self.signature = signature
        self.declarerSendingPublicKey = declarerSendingPublicKey
        self.declaredAt = declaredAt
        self.provenAt = provenAt
    }

    /// Re-verified on every read, never read off a stored flag.
    public func standing(groupID groupIDBytes: Data) -> TreasurySignerStanding {
        guard TreasurySignerDeclaration.isDeclaration(
            signature: signature,
            signerAccount: account,
            groupID: groupIDBytes,
            declarerSendingPublicKey: declarerSendingPublicKey
        ) else { return .doesNotVerify }
        switch source {
        case .onym: return .declaredOnym
        case .external: return provenAt == nil
            ? .declaredExternalUnproven
            : .declaredExternalProven
        }
    }
}
