import Foundation
import OnymFoundation
import OnymIdentity
import OnymStellar
import SwiftData
import os

/// SwiftData-backed `TreasuryStore`. Owns the encrypt/decrypt boundary
/// so the `@Model` types stay free of CryptoKit, matching
/// `SwiftDataMessageStore`.
///
/// A row whose encrypted columns cannot be decoded is **skipped, not
/// deleted**. The same reasoning `PersistentStoreOpener` applies to a
/// whole store applies to a row: an unreadable column is more often a
/// locked keychain or a partial write than corruption, and money state
/// is the last thing that should be quietly discarded on a guess.
public final class SwiftDataTreasuryStore: TreasuryStore, @unchecked Sendable {
    private let container: ModelContainer
    private let context: ModelContext
    private let queue = DispatchQueue(label: "app.onym.ios.treasury-store")
    private static let log = Logger(subsystem: "app.onym.ios", category: "treasury-store")

    public static let schema = Schema([
        PersistedTreasury.self,
        PersistedSignerDeclaration.self,
        PersistedProposal.self,
    ])

    public init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    /// Opens `Treasury.store` beside the other stores, under the same
    /// file-protection and move-aside-on-failure policy.
    public static func onDisk() throws -> SwiftDataTreasuryStore {
        let url = try PersistentStoreOpener.storeDirectory()
            .appendingPathComponent("Treasury.store")
        return SwiftDataTreasuryStore(
            container: try PersistentStoreOpener.openContainer(schema: schema, url: url)
        )
    }

    // MARK: - Treasury

    public func treasury(groupID: String, ownerIDString: String) async -> Treasury? {
        // Double-optional flattened: `perform` reports its own failure
        // as nil, and "no such treasury" is also nil. They mean
        // different things to this store and the same thing to the
        // caller — a group with no treasury it can show.
        await perform { () -> Treasury? in
            guard let row = try self.fetchTreasury(groupID, ownerIDString) else { return nil }
            return try self.decode(row)
        } ?? nil
    }

    public func upsert(_ treasury: Treasury) async {
        let owner = treasury.ownerIdentityID.rawValue.uuidString
        await perform {
            let snapshot = ChainSnapshot(
                signers: treasury.lastKnownSigners.map {
                    ChainSnapshot.Signer(key: $0.key.accountID, weight: $0.weight)
                },
                low: treasury.lastKnownThresholds?.low,
                medium: treasury.lastKnownThresholds?.medium,
                high: treasury.lastKnownThresholds?.high
            )
            let encodedSnapshot = try StorageEncryption.encrypt(
                try JSONEncoder().encode(snapshot)
            )
            if let row = try self.fetchTreasury(treasury.groupID, owner) {
                row.encryptedChainSnapshot = encodedSnapshot
                row.lastRefreshedAt = treasury.lastRefreshedAt
            } else {
                self.context.insert(PersistedTreasury(
                    groupID: treasury.groupID,
                    ownerIdentityIDString: owner,
                    createdAt: treasury.createdAt,
                    encryptedAccountID: try StorageEncryption.encrypt(
                        Data(treasury.account.accountID.utf8)
                    ),
                    encryptedNetwork: try StorageEncryption.encrypt(
                        Data(treasury.network.rawValue.utf8)
                    ),
                    encryptedCreationTxHash: try StorageEncryption.encrypt(
                        Data(treasury.creationTxHash.utf8)
                    ),
                    encryptedChainSnapshot: encodedSnapshot,
                    lastRefreshedAt: treasury.lastRefreshedAt
                ))
            }
            try self.context.save()
            return ()
        }
    }

    public func removeTreasury(groupID: String, ownerIDString: String) async {
        await perform {
            if let row = try self.fetchTreasury(groupID, ownerIDString) {
                self.context.delete(row)
                try self.context.save()
            }
            return ()
        }
    }

    // MARK: - Declarations

    public func declarations(
        groupID: String,
        ownerIDString: String
    ) async -> [TreasurySignerDeclarationRecord] {
        await perform {
            let descriptor = FetchDescriptor<PersistedSignerDeclaration>(
                predicate: #Predicate {
                    $0.groupID == groupID && $0.ownerIdentityIDString == ownerIDString
                }
            )
            return try self.context.fetch(descriptor).compactMap { row in
                do { return try self.decode(row) } catch {
                    Self.log.error("undecodable declaration row, skipping")
                    return nil
                }
            }
        } ?? []
    }

    public func upsert(_ declaration: TreasurySignerDeclarationRecord) async {
        let owner = declaration.ownerIdentityID.rawValue.uuidString
        let group = declaration.groupID
        let member = declaration.memberBlsPubkeyHex
        await perform {
            let descriptor = FetchDescriptor<PersistedSignerDeclaration>(
                predicate: #Predicate {
                    $0.groupID == group
                        && $0.ownerIdentityIDString == owner
                        && $0.memberBlsPubkeyHex == member
                }
            )
            let account = try StorageEncryption.encrypt(
                Data(declaration.account.accountID.utf8)
            )
            let source = try StorageEncryption.encrypt(
                Data(declaration.source.rawValue.utf8)
            )
            let signature = try StorageEncryption.encrypt(declaration.signature)
            let sendingKey = try StorageEncryption.encrypt(
                declaration.declarerSendingPublicKey
            )
            if let row = try self.context.fetch(descriptor).first {
                row.declaredAt = declaration.declaredAt
                row.provenAt = declaration.provenAt
                row.encryptedAccountID = account
                row.encryptedSource = source
                row.encryptedSignature = signature
                row.encryptedDeclarerSendingPublicKey = sendingKey
            } else {
                self.context.insert(PersistedSignerDeclaration(
                    groupID: group,
                    ownerIdentityIDString: owner,
                    memberBlsPubkeyHex: member,
                    declaredAt: declaration.declaredAt,
                    provenAt: declaration.provenAt,
                    encryptedAccountID: account,
                    encryptedSource: source,
                    encryptedSignature: signature,
                    encryptedDeclarerSendingPublicKey: sendingKey
                ))
            }
            try self.context.save()
            return ()
        }
    }

    public func markProven(
        groupID: String,
        ownerIDString: String,
        account: StellarAccountID,
        at: Date
    ) async {
        await perform {
            let descriptor = FetchDescriptor<PersistedSignerDeclaration>(
                predicate: #Predicate {
                    $0.groupID == groupID
                        && $0.ownerIdentityIDString == ownerIDString
                        && $0.provenAt == nil
                }
            )
            var changed = false
            for row in try self.context.fetch(descriptor) {
                // The account lives in an encrypted column, so this
                // cannot be a predicate — the rows are narrowed by the
                // plain columns first and matched here.
                guard let decoded = try? self.decode(row), decoded.account == account else {
                    continue
                }
                row.provenAt = at
                changed = true
            }
            if changed { try self.context.save() }
            return ()
        }
    }

    // MARK: - Proposals

    public func proposals(groupID: String, ownerIDString: String) async -> [StoredProposal] {
        await perform {
            let descriptor = FetchDescriptor<PersistedProposal>(
                predicate: #Predicate {
                    $0.groupID == groupID && $0.ownerIdentityIDString == ownerIDString
                },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            return try self.context.fetch(descriptor).compactMap { row in
                do { return try self.decode(row) } catch {
                    Self.log.error("undecodable proposal row, skipping")
                    return nil
                }
            }
        } ?? []
    }

    public func proposal(id: UUID, ownerIDString: String) async -> StoredProposal? {
        let idString = id.uuidString
        return await perform { () -> StoredProposal? in
            let descriptor = FetchDescriptor<PersistedProposal>(
                predicate: #Predicate {
                    $0.id == idString && $0.ownerIdentityIDString == ownerIDString
                }
            )
            guard let row = try self.context.fetch(descriptor).first else { return nil }
            return try self.decode(row)
        } ?? nil
    }

    public func upsert(_ stored: StoredProposal) async {
        let proposal = stored.proposal
        let owner = proposal.ownerIdentityID.rawValue.uuidString
        let idString = proposal.id.uuidString
        await perform {
            let descriptor = FetchDescriptor<PersistedProposal>(
                predicate: #Predicate {
                    $0.id == idString && $0.ownerIdentityIDString == owner
                }
            )
            let envelope = try StorageEncryption.encrypt(
                Data(proposal.envelope.base64XDR.utf8)
            )
            if let row = try self.context.fetch(descriptor).first {
                row.encryptedEnvelopeXDR = envelope
                row.submittedTxHash = proposal.submittedTxHash
                row.rejectionRaw = stored.rejection?.rawValue
            } else {
                self.context.insert(PersistedProposal(
                    id: idString,
                    groupID: proposal.groupID,
                    ownerIdentityIDString: owner,
                    createdAt: proposal.createdAt,
                    kindRaw: proposal.kind.rawValue,
                    rejectionRaw: stored.rejection?.rawValue,
                    submittedTxHash: proposal.submittedTxHash,
                    encryptedProposerBlsPubkeyHex: try StorageEncryption.encrypt(
                        Data(proposal.proposerBlsPubkeyHex.utf8)
                    ),
                    encryptedTreasuryAccountID: try StorageEncryption.encrypt(
                        Data(proposal.treasuryAccount.accountID.utf8)
                    ),
                    encryptedNetwork: try StorageEncryption.encrypt(
                        Data(proposal.network.rawValue.utf8)
                    ),
                    encryptedEnvelopeXDR: envelope
                ))
            }
            try self.context.save()
            return ()
        }
    }

    public func removeAll(ownerIDString: String) async {
        await perform {
            try self.context.delete(
                model: PersistedTreasury.self,
                where: #Predicate { $0.ownerIdentityIDString == ownerIDString }
            )
            try self.context.delete(
                model: PersistedSignerDeclaration.self,
                where: #Predicate { $0.ownerIdentityIDString == ownerIDString }
            )
            try self.context.delete(
                model: PersistedProposal.self,
                where: #Predicate { $0.ownerIdentityIDString == ownerIDString }
            )
            try self.context.save()
            return ()
        }
    }

    // MARK: - Coding

    /// The cached chain read, as one encrypted JSON blob rather than a
    /// column per field — it is a snapshot to draw, never something
    /// queried.
    private struct ChainSnapshot: Codable {
        struct Signer: Codable {
            let key: String
            let weight: UInt32
        }
        let signers: [Signer]
        let low: UInt32?
        let medium: UInt32?
        let high: UInt32?
    }

    private func fetchTreasury(
        _ groupID: String,
        _ owner: String
    ) throws -> PersistedTreasury? {
        let descriptor = FetchDescriptor<PersistedTreasury>(
            predicate: #Predicate {
                $0.groupID == groupID && $0.ownerIdentityIDString == owner
            }
        )
        return try context.fetch(descriptor).first
    }

    private func decode(_ row: PersistedTreasury) throws -> Treasury {
        var signers: [StellarSigner] = []
        var thresholds: HorizonThresholds?
        if let blob = row.encryptedChainSnapshot,
           let snapshot = try? JSONDecoder().decode(
               ChainSnapshot.self,
               from: try StorageEncryption.decrypt(blob)
           ) {
            signers = snapshot.signers.compactMap {
                guard let key = try? StellarAccountID(accountID: $0.key) else { return nil }
                return StellarSigner(key: key, weight: $0.weight)
            }
            if let low = snapshot.low, let medium = snapshot.medium, let high = snapshot.high {
                thresholds = HorizonThresholds(low: low, medium: medium, high: high)
            }
        }
        return Treasury(
            account: try StellarAccountID(
                accountID: try string(row.encryptedAccountID)
            ),
            groupID: row.groupID,
            ownerIdentityID: try identity(row.ownerIdentityIDString),
            network: try network(row.encryptedNetwork),
            creationTxHash: try string(row.encryptedCreationTxHash),
            createdAt: row.createdAt,
            lastKnownSigners: signers,
            lastKnownThresholds: thresholds,
            lastRefreshedAt: row.lastRefreshedAt
        )
    }

    private func decode(
        _ row: PersistedSignerDeclaration
    ) throws -> TreasurySignerDeclarationRecord {
        let sourceRaw = try string(row.encryptedSource)
        guard let source = TreasurySignerSource(rawValue: sourceRaw) else {
            throw TreasuryStoreError.undecodable("signer source '\(sourceRaw)'")
        }
        return TreasurySignerDeclarationRecord(
            groupID: row.groupID,
            ownerIdentityID: try identity(row.ownerIdentityIDString),
            memberBlsPubkeyHex: row.memberBlsPubkeyHex,
            account: try StellarAccountID(accountID: try string(row.encryptedAccountID)),
            source: source,
            signature: try StorageEncryption.decrypt(row.encryptedSignature),
            declarerSendingPublicKey: try StorageEncryption.decrypt(
                row.encryptedDeclarerSendingPublicKey
            ),
            declaredAt: row.declaredAt,
            provenAt: row.provenAt
        )
    }

    private func decode(_ row: PersistedProposal) throws -> StoredProposal {
        guard let id = UUID(uuidString: row.id) else {
            throw TreasuryStoreError.undecodable("proposal id '\(row.id)'")
        }
        guard let kind = TreasuryProposalKind(rawValue: row.kindRaw) else {
            throw TreasuryStoreError.undecodable("proposal kind '\(row.kindRaw)'")
        }
        let proposal = TreasuryProposal(
            id: id,
            groupID: row.groupID,
            ownerIdentityID: try identity(row.ownerIdentityIDString),
            proposerBlsPubkeyHex: try string(row.encryptedProposerBlsPubkeyHex),
            treasuryAccount: try StellarAccountID(
                accountID: try string(row.encryptedTreasuryAccountID)
            ),
            network: try network(row.encryptedNetwork),
            kind: kind,
            envelope: try TransactionEnvelope(
                base64XDR: try string(row.encryptedEnvelopeXDR)
            ),
            createdAt: row.createdAt,
            submittedTxHash: row.submittedTxHash
        )
        return StoredProposal(
            proposal: proposal,
            rejection: row.rejectionRaw.flatMap(TreasuryRejection.init(rawValue:))
        )
    }

    private func string(_ encrypted: Data) throws -> String {
        let plain = try StorageEncryption.decrypt(encrypted)
        guard let value = String(data: plain, encoding: .utf8) else {
            throw TreasuryStoreError.undecodable("non-UTF8 column")
        }
        return value
    }

    private func network(_ encrypted: Data) throws -> StellarNetwork {
        let raw = try string(encrypted)
        guard let network = StellarNetwork(rawValue: raw) else {
            throw TreasuryStoreError.undecodable("network '\(raw)'")
        }
        return network
    }

    private func identity(_ raw: String) throws -> IdentityID {
        guard let uuid = UUID(uuidString: raw) else {
            throw TreasuryStoreError.undecodable("owner id '\(raw)'")
        }
        return IdentityID(uuid)
    }

    /// Every store call funnels through here so writes serialise on one
    /// queue and a throw becomes `nil` rather than a crash — the same
    /// bargain the other SwiftData stores make.
    @discardableResult
    private func perform<T>(_ body: @escaping () throws -> T) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    Self.log.error("treasury store: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

enum TreasuryStoreError: Error, Equatable {
    case undecodable(String)
}
