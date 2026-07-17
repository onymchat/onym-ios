import Foundation
import SwiftData

/// SwiftData row for one chat message on disk. Same plain-vs-encrypted
/// split as `PersistedGroup`: anything we need to filter or sort on
/// stays plain; sensitive content rides through `StorageEncryption`.
///
/// Plain:
/// - `id` — UUID string. Drives receive-side dedup (`@Attribute(.unique)`).
/// - `groupID` — 64-char hex of the parent group; predicate-filterable.
/// - `ownerIdentityIDString` — identity that owns the row; cascade
///   delete on identity removal needs a predicate over this.
/// - `sentAt` — sort column for the chat scroll order.
/// - `directionRaw`, `statusRaw`, `groupTypeRaw` — small enums.
/// - `replyToMessageIDString` — optional UUID of the replied-to
///   message. Plain (not sensitive — it's just a pointer to another
///   row in this same table) and left queryable for a future
///   "replies to X" lookup. Optional, so adding it is a SwiftData
///   lightweight migration over the existing store.
///
/// Encrypted (`StorageEncryption.encrypt`):
/// - `senderBlsPubkeyHex` — group-membership identifier; consistent
///   with the encrypted `memberProfiles` column on `PersistedGroup`.
/// - `body` — user-supplied message text.
///
/// Decryption boundary lives in `SwiftDataMessageStore`, not here —
/// the @Model stays dumb so the macro doesn't have to reason about
/// CryptoKit types.
@Model
final class PersistedMessage {
    @Attribute(.unique) var id: String
    var groupID: String
    var ownerIdentityIDString: String
    var sentAt: Date
    var directionRaw: String
    var statusRaw: String
    var groupTypeRaw: String
    var replyToMessageIDString: String?

    var encryptedSenderBlsPubkeyHex: Data
    var encryptedBody: Data

    init(
        id: String,
        groupID: String,
        ownerIdentityIDString: String,
        sentAt: Date,
        directionRaw: String,
        statusRaw: String,
        groupTypeRaw: String,
        replyToMessageIDString: String?,
        encryptedSenderBlsPubkeyHex: Data,
        encryptedBody: Data
    ) {
        self.id = id
        self.groupID = groupID
        self.ownerIdentityIDString = ownerIdentityIDString
        self.sentAt = sentAt
        self.directionRaw = directionRaw
        self.statusRaw = statusRaw
        self.groupTypeRaw = groupTypeRaw
        self.replyToMessageIDString = replyToMessageIDString
        self.encryptedSenderBlsPubkeyHex = encryptedSenderBlsPubkeyHex
        self.encryptedBody = encryptedBody
    }
}
