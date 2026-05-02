import Foundation

/// Snapshot of the user's persisted identity, as projected to views.
///
/// Value type — immutable, `Sendable`, safe to pass across actor boundaries.
/// Constructed by `IdentityRepository` from the on-device secrets; views
/// never see secret material directly.
struct Identity: Sendable, Equatable {
    /// 32-byte BIP340 x-only secp256k1 public key (Nostr npub source).
    let nostrPublicKey: Data
    /// 48-byte BLS12-381 G1 compressed public key (SEP group membership).
    let blsPublicKey: Data
    /// 12-word BIP39 recovery phrase, or `nil` for an identity that was
    /// loaded from raw key material without an associated mnemonic.
    let recoveryPhrase: String?
}
