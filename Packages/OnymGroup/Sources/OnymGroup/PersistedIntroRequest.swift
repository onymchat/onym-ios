import Foundation
import SwiftData
import OnymFoundation

/// SwiftData row for one pending join request. Same plain-vs-encrypted
/// split as `PersistedMessage` / `PersistedGroup`: anything we filter or
/// sort on stays plain, the sensitive bytes ride through
/// `StorageEncryption`.
///
/// Plain:
/// - `id` — the Nostr event id, already the dedup key on the in-memory
///   store. Unique, so a relay replaying the same event on reconnect
///   collapses onto the existing row instead of stacking duplicates.
/// - `receivedAt` — sort column (newest-first, matching the in-memory
///   store's ordering).
///
/// Encrypted:
/// - `targetIntroPublicKey` — correlates the request to a specific
///   invite link; on its own it would tell anyone with the store file
///   which invite a request came in on.
/// - `payload` — the sealed envelope. Already encrypted to the intro
///   key, so this is belt-and-braces, but it costs nothing and keeps the
///   column posture uniform across stores.
@Model
final class PersistedIntroRequest {
    @Attribute(.unique) var id: String
    var receivedAt: Date

    var encryptedTargetIntroPublicKey: Data
    var encryptedPayload: Data

    init(
        id: String,
        receivedAt: Date,
        encryptedTargetIntroPublicKey: Data,
        encryptedPayload: Data
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.encryptedTargetIntroPublicKey = encryptedTargetIntroPublicKey
        self.encryptedPayload = encryptedPayload
    }
}
