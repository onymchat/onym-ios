import Foundation
import SwiftData

/// SwiftData row for one chat group on disk. Splits the schema into
/// plain (queryable, non-identifying) and AES-GCM-encrypted (sensitive)
/// columns — same pattern as `PersistedInvitation` (PR #16).
///
/// Plain:
/// - `id` — 64-char hex of the 32-byte group ID. Already public on-chain
///   (the contract stores it as the entry key), so encrypting locally
///   would buy nothing while breaking dedup lookups.
/// - `createdAt`, `epoch`, `tierRaw`, `groupTypeRaw`,
///   `isPublishedOnChain` — small enums / counts; not user-identifying.
///
/// Encrypted (`StorageEncryption.encrypt`):
/// - `name` — user-supplied; can leak intent.
/// - `groupSecret` — drives all message-key derivation.
/// - `membersJSON` — the lex-sorted roster (BLS pubkeys + leaf hashes).
/// - `memberProfilesJSON` — alias + inbox-key per member (sparse map).
/// - `salt`, `commitment`, `adminPubkeyHex`.
///
/// Decryption boundary lives in `SwiftDataGroupStore`, not here —
/// `PersistedGroup` is intentionally dumb storage so the @Model macro
/// doesn't have to reason about CryptoKit types.
@Model
final class PersistedGroup {
    /// Uniqueness is the **composite** `(id, ownerIdentityIDString)`,
    /// not `id` alone. The same on-chain group can be joined by more
    /// than one identity on a single device (e.g. one identity invites
    /// another to the same chat); each identity must keep its own row.
    /// Keying on `id` alone made the second joiner's row overwrite the
    /// first — "last invited identity wins", and the chat vanished for
    /// the earlier one.
    #Unique<PersistedGroup>([\.id, \.ownerIdentityIDString])

    /// 64-char hex of the 32-byte group ID. Not unique on its own —
    /// see the `#Unique` composite above.
    var id: String
    /// UUID string of the identity that owns this row. Plain (not
    /// encrypted) so SwiftData `#Predicate` can filter on it. Owner
    /// IDs are random per-device UUIDs — no cross-device linkage,
    /// nothing to leak. Part of the composite uniqueness key.
    var ownerIdentityIDString: String
    var createdAt: Date
    var epoch: Int64
    var tierRaw: Int
    var groupTypeRaw: String
    var isPublishedOnChain: Bool
    /// When the local user last opened / read this thread — drives the
    /// chat-list unread badge. Plain (a timestamp isn't user-identifying)
    /// and optional so SwiftData's lightweight migration lands the column
    /// on existing rows without a wipe; `nil` = never opened.
    var lastReadAt: Date?

    var encryptedName: Data
    var encryptedGroupSecret: Data
    var encryptedMembersJSON: Data
    var encryptedSalt: Data
    var encryptedCommitment: Data?
    var encryptedAdminPubkeyHex: Data?
    /// Optional so SwiftData's lightweight migration can land an extra
    /// column on existing rows without a wipe. `nil` decodes to `[:]`.
    var encryptedMemberProfilesJSON: Data?
    /// Optional Ed25519 pubkey of the admin (PR 9). `nil` on rows
    /// migrated from pre-PR-9 schema, or for governance models
    /// without an admin.
    var encryptedAdminEd25519PubkeyHex: Data?
    /// Optional square JPEG group photo. Optional so SwiftData's
    /// lightweight migration lands the column on existing rows without a
    /// wipe; `nil` decodes to "no avatar" (brand-mark fallback).
    var encryptedAvatar: Data?
    /// Optional encrypted invitation message (the group's intro / policy).
    /// Optional so SwiftData's lightweight migration lands the column on
    /// existing rows without a wipe; `nil` decodes to "no invitation".
    var encryptedInvitationMessage: Data?

    init(
        id: String,
        ownerIdentityIDString: String,
        createdAt: Date,
        epoch: Int64,
        tierRaw: Int,
        groupTypeRaw: String,
        isPublishedOnChain: Bool,
        lastReadAt: Date? = nil,
        encryptedName: Data,
        encryptedGroupSecret: Data,
        encryptedMembersJSON: Data,
        encryptedSalt: Data,
        encryptedCommitment: Data?,
        encryptedAdminPubkeyHex: Data?,
        encryptedMemberProfilesJSON: Data?,
        encryptedAdminEd25519PubkeyHex: Data?,
        encryptedAvatar: Data? = nil,
        encryptedInvitationMessage: Data? = nil
    ) {
        self.id = id
        self.ownerIdentityIDString = ownerIdentityIDString
        self.createdAt = createdAt
        self.epoch = epoch
        self.tierRaw = tierRaw
        self.groupTypeRaw = groupTypeRaw
        self.isPublishedOnChain = isPublishedOnChain
        self.lastReadAt = lastReadAt
        self.encryptedName = encryptedName
        self.encryptedGroupSecret = encryptedGroupSecret
        self.encryptedMembersJSON = encryptedMembersJSON
        self.encryptedSalt = encryptedSalt
        self.encryptedCommitment = encryptedCommitment
        self.encryptedAdminPubkeyHex = encryptedAdminPubkeyHex
        self.encryptedMemberProfilesJSON = encryptedMemberProfilesJSON
        self.encryptedAdminEd25519PubkeyHex = encryptedAdminEd25519PubkeyHex
        self.encryptedAvatar = encryptedAvatar
        self.encryptedInvitationMessage = encryptedInvitationMessage
    }
}
