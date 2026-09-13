import Foundation
import OnymFoundation
import SwiftData

/// SwiftData rows for the treasury store, following the same
/// plain-vs-encrypted split as `PersistedMessage`: anything filtered or
/// sorted on stays plain, anything that identifies people or their
/// money rides through `StorageEncryption`.
///
/// Its own store (`Treasury.store`) rather than columns on
/// `PersistedGroup`. The group store is not the owner of money state,
/// proposals have a lifecycle of their own, and keeping them apart
/// means none of this can put a migration in front of somebody's
/// existing chats.
///
/// The decryption boundary lives in `SwiftDataTreasuryStore`; these
/// models stay dumb so the macro never has to reason about CryptoKit
/// types.
@Model
final class PersistedTreasury {
    /// A group has at most one treasury, per identity — the same
    /// composite-key reasoning as `PersistedMessage`: two local
    /// identities can both be members of one group, and each keeps its
    /// own row rather than overwriting the other's.
    #Unique<PersistedTreasury>([\.groupID, \.ownerIdentityIDString])

    var groupID: String
    var ownerIdentityIDString: String
    var createdAt: Date

    /// The `G…` account. Encrypted: it links this group to a public
    /// ledger history, which is exactly the association a device that
    /// falls into someone else's hands should not hand over.
    var encryptedAccountID: Data
    var encryptedNetwork: Data
    var encryptedCreationTxHash: Data
    /// JSON snapshot of the last signer set and thresholds read from
    /// the chain. A cache for first paint only — never what decides
    /// whether a proposal has enough weight.
    var encryptedChainSnapshot: Data?
    var lastRefreshedAt: Date?

    init(
        groupID: String,
        ownerIdentityIDString: String,
        createdAt: Date,
        encryptedAccountID: Data,
        encryptedNetwork: Data,
        encryptedCreationTxHash: Data,
        encryptedChainSnapshot: Data?,
        lastRefreshedAt: Date?
    ) {
        self.groupID = groupID
        self.ownerIdentityIDString = ownerIdentityIDString
        self.createdAt = createdAt
        self.encryptedAccountID = encryptedAccountID
        self.encryptedNetwork = encryptedNetwork
        self.encryptedCreationTxHash = encryptedCreationTxHash
        self.encryptedChainSnapshot = encryptedChainSnapshot
        self.lastRefreshedAt = lastRefreshedAt
    }
}

/// One member's declared co-signer account.
@Model
final class PersistedSignerDeclaration {
    /// One declaration per member per group per identity. A member who
    /// re-declares replaces their own row rather than accumulating —
    /// changing your mind about which account to use is ordinary, and
    /// a history of superseded declarations is a record of nothing.
    #Unique<PersistedSignerDeclaration>([
        \.groupID, \.ownerIdentityIDString, \.memberBlsPubkeyHex,
    ])

    var groupID: String
    var ownerIdentityIDString: String
    /// Plain: it is the lookup key against the group roster, and it is
    /// already stored plainly as the message sender column.
    var memberBlsPubkeyHex: String
    var declaredAt: Date
    /// Set once this account has produced a valid signature over one of
    /// the group's transactions — the only evidence that an externally
    /// held account is really theirs.
    var provenAt: Date?

    var encryptedAccountID: Data
    var encryptedSource: Data
    /// The declarer's signature and the key it is checked against, kept
    /// together. A signature without the bytes that verify it proves
    /// that something was declared and never what.
    var encryptedSignature: Data
    var encryptedDeclarerSendingPublicKey: Data

    init(
        groupID: String,
        ownerIdentityIDString: String,
        memberBlsPubkeyHex: String,
        declaredAt: Date,
        provenAt: Date?,
        encryptedAccountID: Data,
        encryptedSource: Data,
        encryptedSignature: Data,
        encryptedDeclarerSendingPublicKey: Data
    ) {
        self.groupID = groupID
        self.ownerIdentityIDString = ownerIdentityIDString
        self.memberBlsPubkeyHex = memberBlsPubkeyHex
        self.declaredAt = declaredAt
        self.provenAt = provenAt
        self.encryptedAccountID = encryptedAccountID
        self.encryptedSource = encryptedSource
        self.encryptedSignature = encryptedSignature
        self.encryptedDeclarerSendingPublicKey = encryptedDeclarerSendingPublicKey
    }
}

/// A proposal and the signatures gathered for it.
@Model
final class PersistedProposal {
    #Unique<PersistedProposal>([\.id, \.ownerIdentityIDString])

    var id: String
    var groupID: String
    var ownerIdentityIDString: String
    /// Sort column for the thread and the treasury screen.
    var createdAt: Date
    var kindRaw: String
    /// `TreasuryRejection` raw value when this device refused the
    /// proposal. The row is kept rather than dropped: a refusal that
    /// leaves no trace looks identical to a message that never arrived,
    /// and one of those is worth telling someone about.
    var rejectionRaw: String?
    /// Non-nil once the network applied it.
    var submittedTxHash: String?

    var encryptedProposerBlsPubkeyHex: Data
    var encryptedTreasuryAccountID: Data
    var encryptedNetwork: Data
    /// Base64 envelope XDR, carrying the transaction **and** every
    /// signature collected so far. One column rather than a transaction
    /// plus a signature table, because the envelope is the unit that
    /// gets submitted and splitting it would invite the two halves to
    /// disagree.
    var encryptedEnvelopeXDR: Data

    init(
        id: String,
        groupID: String,
        ownerIdentityIDString: String,
        createdAt: Date,
        kindRaw: String,
        rejectionRaw: String?,
        submittedTxHash: String?,
        encryptedProposerBlsPubkeyHex: Data,
        encryptedTreasuryAccountID: Data,
        encryptedNetwork: Data,
        encryptedEnvelopeXDR: Data
    ) {
        self.id = id
        self.groupID = groupID
        self.ownerIdentityIDString = ownerIdentityIDString
        self.createdAt = createdAt
        self.kindRaw = kindRaw
        self.rejectionRaw = rejectionRaw
        self.submittedTxHash = submittedTxHash
        self.encryptedProposerBlsPubkeyHex = encryptedProposerBlsPubkeyHex
        self.encryptedTreasuryAccountID = encryptedTreasuryAccountID
        self.encryptedNetwork = encryptedNetwork
        self.encryptedEnvelopeXDR = encryptedEnvelopeXDR
    }
}
