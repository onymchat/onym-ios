import Foundation

/// Snapshot of the user's persisted identity, as projected to views.
///
/// Value type — immutable, `Sendable`, safe to pass across actor boundaries.
/// Constructed by `IdentityRepository` from the on-device secrets; views
/// never see secret material directly.
///
/// Two of the keypairs are persisted (nostr secp256k1, BLS12-381) and two
/// are HKDF-derived from the nostr secret on every load (Stellar Ed25519
/// for on-chain identity + envelope signing, X25519 for invitation ECDH).
/// The private halves of the derived pairs stay inside the repository;
/// only the pubkeys/identifiers projected here are visible to callers.
struct Identity: Sendable, Equatable {
    /// 32-byte BIP340 x-only secp256k1 public key (Nostr npub source).
    let nostrPublicKey: Data
    /// 48-byte BLS12-381 G1 compressed public key (SEP group membership).
    let blsPublicKey: Data
    /// 32-byte Ed25519 public key (raw representation). Doubles as the
    /// Stellar account public key and the verifying key for envelope
    /// signatures + transport-bundle binding signatures.
    let stellarPublicKey: Data
    /// Stellar StrKey account ID (`G...`), used as `callerAddress` on
    /// every Soroban contract call.
    let stellarAccountID: String
    /// 32-byte X25519 public key (raw representation). Permanent ECDH
    /// key — senders ECDH against this to encrypt invitations to us.
    let inboxPublicKey: Data
    /// 16-char hex of `SHA-256("sep-inbox-v1" || inboxPublicKey)[0..8]`.
    /// Discoverable inbox handle posted as a Nostr `#t` / `#d` filter
    /// tag so peers can address invites to us without leaking the X25519
    /// pubkey on-relay.
    let inboxTag: String
    /// 12-word BIP39 recovery phrase, or `nil` for an identity that was
    /// loaded from raw key material without an associated mnemonic.
    let recoveryPhrase: String?
}
