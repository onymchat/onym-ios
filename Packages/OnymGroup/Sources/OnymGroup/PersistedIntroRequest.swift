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
    /// The sender's claim of when they sent, used for display order
    /// only. Sourced from the Nostr event's `ms` tag, which the *joiner*
    /// writes — so it is an assertion, not an observation, and nothing
    /// that decides whether a row lives or dies may read it.
    var receivedAt: Date
    /// When this device first wrote the row. Local clock, set once at
    /// `record` and never updated.
    ///
    /// Retention prunes on this rather than `receivedAt`, because
    /// `receivedAt` is attacker- and clock-controlled. Pruning on it
    /// would mean a founder offline past the retention window has every
    /// replayed request swept on the first read — never seeing a request
    /// the joiner is still waiting on, which is the failure this whole
    /// change exists to fix — and a joiner who stamps `ms` far in the
    /// future gets a row that never expires.
    ///
    /// Optional so adding it is a SwiftData lightweight migration; nil
    /// rows (written before this column existed) are treated as
    /// first-seen now, which grants them a fresh window rather than
    /// sweeping them on sight.
    var firstSeenAt: Date?

    var encryptedTargetIntroPublicKey: Data
    var encryptedPayload: Data

    init(
        id: String,
        receivedAt: Date,
        firstSeenAt: Date,
        encryptedTargetIntroPublicKey: Data,
        encryptedPayload: Data
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.firstSeenAt = firstSeenAt
        self.encryptedTargetIntroPublicKey = encryptedTargetIntroPublicKey
        self.encryptedPayload = encryptedPayload
    }
}
