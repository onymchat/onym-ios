import Foundation

/// User-facing parsed shape of a received invitation. Decoded from the
/// JSON plaintext that comes out of `IdentityRepository.decryptInvitation`.
///
/// This is a deliberate **subset** of the stellar-mls `BootstrapPayload`
/// wire format — only the fields a recipient needs to display the
/// invitation in a list. `Codable` ignores unknown JSON fields by
/// default, so a future PR can add `members` / `groupSecret` /
/// `relayHints` / `salt` (everything needed to actually join the group)
/// without breaking decode of older payloads or requiring a wire format
/// change. Senders writing the full stellar-mls payload decode here
/// fine.
struct DecryptedInvitation: Codable, Equatable, Sendable {
    /// Group identifier — 32 bytes on the wire (binary), shown as hex
    /// when surfacing to UI.
    let groupID: Data
    /// Display name of the group at invite time.
    let name: String
    /// Group epoch when the invitation was issued.
    let epoch: UInt64
    /// Sender's stable Nostr pubkey (BIP340 x-only, 32-byte hex). Note:
    /// the *event* pubkey on the kind 34113 envelope is ephemeral
    /// per-event and meaningless for sender identity — this field
    /// (carried inside the encrypted payload) is what to show.
    let senderNostrPubkey: String
}
