import Foundation
import SwiftData
import OnymFoundation

/// SwiftData row for one pending chat. Same plain-vs-encrypted split as
/// `PersistedGroup` / `PersistedIntroRequest`: what we filter or sort on
/// stays plain, everything a person wrote or is addressed by rides
/// through `StorageEncryption`.
///
/// Plain:
/// - `id` — `<group id hex>:<owner uuid>`. The group id is already
///   public on-chain and the owner id is a random per-device UUID, so
///   encrypting the key would buy nothing and break dedup lookups.
/// - `ownerIdentityIDString` — the `#Predicate` filter for the
///   identity-removal cascade.
/// - `receivedAt` — the sort column.
/// - `statusRaw` / `failureRaw` — which waiting state this is, as
///   codes rather than sentences, so re-wording or re-translating the
///   copy is not a migration.
///
/// Encrypted:
/// - `introPublicKey` — correlates this device to a specific invite link.
/// - `groupName`, `inviterAlias`, `invitationMessage` — all
///   user-supplied, all leak intent.
@Model
final class PersistedPendingChat {
    @Attribute(.unique) var id: String
    var ownerIdentityIDString: String
    /// Lowercase hex of the group id, and the *only* copy of it.
    ///
    /// Plain because it is how `PendingVerificationStore` names a group
    /// and how the sweep matches rows, both of which have to compare
    /// without decrypting anything — and because a group id is public
    /// on-chain, which is the same argument `id` makes one field up.
    /// It was also stored encrypted alongside this, which bought no
    /// confidentiality and added a decrypt that could fail and take the
    /// row with it. The bytes are derived from here.
    var groupIDHex: String
    var receivedAt: Date
    /// `offered` / `requested` / `failed`. A raw string rather than an
    /// enum so the column is a persistence format that survives the
    /// Swift type being re-shaped.
    var statusRaw: String
    /// Only set for `failed` — a `PendingChat.SendFailure` raw value.
    var failureRaw: String?

    var encryptedIntroPublicKey: Data
    /// Nil when the invite carried no group name — distinct from an
    /// empty name, which the row would keep as encrypted emptiness.
    var encryptedGroupName: Data?
    var encryptedInviterAlias: Data
    var encryptedInvitationMessage: Data?

    init(
        id: String,
        ownerIdentityIDString: String,
        groupIDHex: String,
        receivedAt: Date,
        statusRaw: String,
        failureRaw: String?,
        encryptedIntroPublicKey: Data,
        encryptedGroupName: Data?,
        encryptedInviterAlias: Data,
        encryptedInvitationMessage: Data?
    ) {
        self.id = id
        self.ownerIdentityIDString = ownerIdentityIDString
        self.groupIDHex = groupIDHex
        self.receivedAt = receivedAt
        self.statusRaw = statusRaw
        self.failureRaw = failureRaw
        self.encryptedIntroPublicKey = encryptedIntroPublicKey
        self.encryptedGroupName = encryptedGroupName
        self.encryptedInviterAlias = encryptedInviterAlias
        self.encryptedInvitationMessage = encryptedInvitationMessage
    }
}
