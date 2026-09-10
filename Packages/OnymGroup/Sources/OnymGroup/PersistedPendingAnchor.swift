import Foundation
import SwiftData

/// SwiftData row for one in-flight anchor attempt. Same
/// plain-vs-encrypted split as `PersistedGroup` /
/// `PersistedIntroRequest`: anything queried on stays plain, the
/// sensitive bytes ride through `StorageEncryption`.
///
/// Plain:
/// - `groupIDHex` / `ownerIdentityIDString` — the lookup key.
/// - `epochOld` — decides which rows can still be waiting to land and
///   which are swept.
/// - `createdAt` — newest-first ordering, so the most recent attempt is
///   checked against the chain first.
///
/// Encrypted:
/// - `encryptedSaltNew` — the blinding factor for a state that may
///   already be on a public chain. In the clear, the store file would
///   let anyone holding it confirm a guessed roster against that
///   commitment — the one thing the salt exists to prevent.
/// - `encryptedJoinerPublicKey` / `encryptedJoinerLeafHash` — who was
///   being added, and to whom the leaf belongs.
///
/// Deliberately *not* `@Attribute(.unique)` on any natural key. Each
/// retry of the same join draws a new salt, and every one of them is a
/// candidate for having landed; collapsing them on
/// `(group, owner, joiner, epoch)` would keep only the last, which is
/// reliably the one that didn't.
@Model
final class PersistedPendingAnchor {
    var groupIDHex: String
    var ownerIdentityIDString: String
    /// SwiftData has no `UInt64` column; stored as the raw bits and
    /// read back with `UInt64(bitPattern:)`, which round-trips every
    /// value.
    var epochOldBits: Int64
    var createdAt: Date

    var encryptedJoinerPublicKey: Data
    var encryptedJoinerLeafHash: Data
    var encryptedSaltNew: Data

    init(
        groupIDHex: String,
        ownerIdentityIDString: String,
        epochOldBits: Int64,
        createdAt: Date,
        encryptedJoinerPublicKey: Data,
        encryptedJoinerLeafHash: Data,
        encryptedSaltNew: Data
    ) {
        self.groupIDHex = groupIDHex
        self.ownerIdentityIDString = ownerIdentityIDString
        self.epochOldBits = epochOldBits
        self.createdAt = createdAt
        self.encryptedJoinerPublicKey = encryptedJoinerPublicKey
        self.encryptedJoinerLeafHash = encryptedJoinerLeafHash
        self.encryptedSaltNew = encryptedSaltNew
    }
}
