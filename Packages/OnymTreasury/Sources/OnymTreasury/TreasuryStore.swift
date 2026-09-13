import Foundation
import OnymIdentity
import OnymStellar

/// Persistence seam for treasuries, declarations and proposals.
///
/// Async surface mirroring `MessageStore` / `GroupStore`, so the
/// concrete implementation can serialise its writes without forcing
/// callers onto a particular actor, and so tests substitute an
/// in-memory conformer rather than standing up SwiftData.
///
/// Everything is scoped by `ownerIDString`. Two local identities can
/// both be in one group, and each keeps its own view of that group's
/// treasury — including its own record of which proposals it refused.
public protocol TreasuryStore: Sendable {
    func treasury(groupID: String, ownerIDString: String) async -> Treasury?
    func upsert(_ treasury: Treasury) async
    func removeTreasury(groupID: String, ownerIDString: String) async

    func declarations(
        groupID: String,
        ownerIDString: String
    ) async -> [TreasurySignerDeclarationRecord]
    /// Replaces any existing declaration by the same member — see
    /// `PersistedSignerDeclaration`'s uniqueness note.
    func upsert(_ declaration: TreasurySignerDeclarationRecord) async
    /// Record that `account` has demonstrated control by signing.
    func markProven(
        groupID: String,
        ownerIDString: String,
        account: StellarAccountID,
        at: Date
    ) async

    /// Proposals for one group, newest first.
    func proposals(groupID: String, ownerIDString: String) async -> [StoredProposal]
    func proposal(id: UUID, ownerIDString: String) async -> StoredProposal?
    func upsert(_ proposal: StoredProposal) async

    /// A creation handed to a wallet and not yet confirmed. At most one
    /// per group.
    func pendingCreation(
        groupID: String,
        ownerIDString: String
    ) async -> PendingTreasuryCreation?
    func upsert(_ pending: PendingTreasuryCreation) async
    func removePendingCreation(groupID: String, ownerIDString: String) async

    /// Every proposal this identity holds that has not been submitted,
    /// across all groups.
    ///
    /// Exists for one caller: a signed transaction coming back from a
    /// wallet carries no group id, so the only way to attribute it is
    /// to offer it to each open proposal and let the signature decide.
    /// Exactly one transaction hash can accept it, and a signature that
    /// matches none is simply not adopted.
    func openProposals(ownerIDString: String) async -> [StoredProposal]

    /// Every row belonging to an identity, for cascade delete on
    /// identity removal.
    func removeAll(ownerIDString: String) async
}

/// A proposal as the store holds it: the domain value plus this
/// device's own refusal, if it refused.
///
/// The rejection lives beside the proposal rather than inside it
/// because it is a fact about *this device's* reading, not about the
/// proposal — a peer on a different build may have accepted the same
/// bytes, and flattening the two would lose that distinction.
public struct StoredProposal: Equatable, Sendable {
    public var proposal: TreasuryProposal
    public var rejection: TreasuryRejection?
    /// When this device set the proposal aside. Local to the device and
    /// never broadcast — dismissing is not a vote, and telling the
    /// group would make it look like one.
    public var dismissedAt: Date?

    public init(
        proposal: TreasuryProposal,
        rejection: TreasuryRejection? = nil,
        dismissedAt: Date? = nil
    ) {
        self.proposal = proposal
        self.rejection = rejection
        self.dismissedAt = dismissedAt
    }
}

/// In-memory conformer. Used by tests, and as the fallback when the
/// on-disk store cannot be opened — the same posture the message and
/// group stores take, where a device that cannot persist still works
/// for the session rather than refusing to start.
public actor InMemoryTreasuryStore: TreasuryStore {
    private var treasuries: [Key: Treasury] = [:]
    private var declarations: [Key: [String: TreasurySignerDeclarationRecord]] = [:]
    private var proposals: [String: StoredProposal] = [:]
    private var pending: [Key: PendingTreasuryCreation] = [:]

    private struct Key: Hashable {
        let groupID: String
        let owner: String
    }

    public init() {}

    public func treasury(groupID: String, ownerIDString: String) -> Treasury? {
        treasuries[Key(groupID: groupID, owner: ownerIDString)]
    }

    public func upsert(_ treasury: Treasury) {
        let key = Key(
            groupID: treasury.groupID,
            owner: treasury.ownerIdentityID.rawValue.uuidString
        )
        treasuries[key] = treasury
    }

    public func removeTreasury(groupID: String, ownerIDString: String) {
        treasuries[Key(groupID: groupID, owner: ownerIDString)] = nil
    }

    public func declarations(
        groupID: String,
        ownerIDString: String
    ) -> [TreasurySignerDeclarationRecord] {
        Array(declarations[Key(groupID: groupID, owner: ownerIDString)]?.values ?? [:].values)
    }

    public func upsert(_ declaration: TreasurySignerDeclarationRecord) {
        let key = Key(
            groupID: declaration.groupID,
            owner: declaration.ownerIdentityID.rawValue.uuidString
        )
        declarations[key, default: [:]][declaration.memberBlsPubkeyHex] = declaration
    }

    public func markProven(
        groupID: String,
        ownerIDString: String,
        account: StellarAccountID,
        at: Date
    ) {
        let key = Key(groupID: groupID, owner: ownerIDString)
        guard var bucket = declarations[key] else { return }
        for (member, record) in bucket where record.account == account {
            guard record.provenAt == nil else { continue }
            var updated = record
            updated.provenAt = at
            bucket[member] = updated
        }
        declarations[key] = bucket
    }

    public func proposals(groupID: String, ownerIDString: String) -> [StoredProposal] {
        proposals.values
            .filter {
                $0.proposal.groupID == groupID
                    && $0.proposal.ownerIdentityID.rawValue.uuidString == ownerIDString
            }
            .sorted { $0.proposal.createdAt > $1.proposal.createdAt }
    }

    public func proposal(id: UUID, ownerIDString: String) -> StoredProposal? {
        proposals[Self.key(id: id, owner: ownerIDString)]
    }

    public func upsert(_ proposal: StoredProposal) {
        let key = Self.key(
            id: proposal.proposal.id,
            owner: proposal.proposal.ownerIdentityID.rawValue.uuidString
        )
        proposals[key] = proposal
    }

    public func pendingCreation(
        groupID: String,
        ownerIDString: String
    ) -> PendingTreasuryCreation? {
        pending[Key(groupID: groupID, owner: ownerIDString)]
    }

    public func upsert(_ record: PendingTreasuryCreation) {
        pending[Key(
            groupID: record.groupID,
            owner: record.ownerIdentityID.rawValue.uuidString
        )] = record
    }

    public func removePendingCreation(groupID: String, ownerIDString: String) {
        pending[Key(groupID: groupID, owner: ownerIDString)] = nil
    }

    public func openProposals(ownerIDString: String) -> [StoredProposal] {
        proposals.values.filter {
            $0.proposal.ownerIdentityID.rawValue.uuidString == ownerIDString
                && $0.proposal.submittedTxHash == nil
                && $0.rejection == nil
        }
    }

    public func removeAll(ownerIDString: String) {
        treasuries = treasuries.filter { $0.key.owner != ownerIDString }
        declarations = declarations.filter { $0.key.owner != ownerIDString }
        proposals = proposals.filter {
            $0.value.proposal.ownerIdentityID.rawValue.uuidString != ownerIDString
        }
        pending = pending.filter { $0.key.owner != ownerIDString }
    }

    private static func key(id: UUID, owner: String) -> String {
        "\(id.uuidString):\(owner)"
    }
}
