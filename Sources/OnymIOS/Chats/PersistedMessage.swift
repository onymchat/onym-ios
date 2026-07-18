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
    /// Uniqueness is the **composite** `(id, ownerIdentityIDString)`,
    /// not `id` alone. The wire `messageID` is minted once by the
    /// sender and fanned out to every recipient inbox, so when two
    /// local identities are both members of a group the same id lands
    /// twice — once per identity. Keying on `id` alone let the second
    /// arrival overwrite the first (and could flip an outgoing row to
    /// incoming). Each identity keeps its own row. Mirrors the
    /// composite key on `PersistedGroup`.
    #Unique<PersistedMessage>([\.id, \.ownerIdentityIDString])

    /// UUID string of the wire `messageID`. Not unique on its own —
    /// see the `#Unique` composite above.
    var id: String
    var groupID: String
    /// Part of the composite uniqueness key; scopes reads and
    /// receive-side dedup to one identity.
    var ownerIdentityIDString: String
    var sentAt: Date
    var directionRaw: String
    var statusRaw: String
    var groupTypeRaw: String
    var replyToMessageIDString: String?
    /// `SendFailureReason` raw value for a `.failed` outgoing row, nil
    /// otherwise. Plain (not sensitive — a coarse error category) and
    /// optional, so adding it is a SwiftData lightweight migration
    /// over the existing store — same shape as `replyToMessageIDString`.
    var failureReasonRaw: String?

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
        failureReasonRaw: String?,
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
        self.failureReasonRaw = failureReasonRaw
        self.encryptedSenderBlsPubkeyHex = encryptedSenderBlsPubkeyHex
        self.encryptedBody = encryptedBody
    }
}
