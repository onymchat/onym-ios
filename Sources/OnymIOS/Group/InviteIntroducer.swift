import Foundation
import CryptoKit

/// Mints fresh per-invite X25519 keypairs and persists them via
/// `IntroKeyStore`. Returns an `IntroCapability` (the public-facing
/// deeplink payload) — the caller drops it into a deeplink URL and
/// shares.
///
/// **Threading**: actor-isolated. Keypair generation is microseconds;
/// the Keychain write is the dominant cost (single `SecItemUpdate`).
/// Cheap enough for the foreground tap handler to await directly.
///
/// **Why one keypair per invite instead of one per identity**: per-
/// link revocation. The inviter can stop listening on a specific
/// intro tag → that link goes silent without affecting other
/// outstanding invites. A leaked link only burns its own slot.
actor InviteIntroducer {
    private let store: any IntroKeyStore
    private let now: @Sendable () -> Date

    init(store: any IntroKeyStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Mint a fresh intro keypair, persist it, and return the
    /// `IntroCapability` the caller will pack into a deeplink URL.
    ///
    /// - Parameters:
    ///   - ownerIdentityID: the identity that's inviting. Used for
    ///     cascade-delete when the identity is removed.
    ///   - groupId: the on-chain `group_id` the invite is for.
    ///     Must be 32 bytes — throws `IntroducerError.invalidGroupID`
    ///     otherwise.
    ///   - groupName: optional plaintext name surfaced in the deeplink
    ///     for the joiner's preview. Pass nil for groups whose name
    ///     is sensitive (deeplink transits cleartext channels).
    func mint(
        ownerIdentityID: IdentityID,
        groupId: Data,
        groupName: String? = nil
    ) async throws -> IntroCapability {
        guard groupId.count == 32 else {
            throw IntroducerError.invalidGroupID(actualSize: groupId.count)
        }

        // CryptoKit handles X25519 scalar clamping internally.
        // `.rawRepresentation` returns the canonical 32-byte form
        // for both the secret scalar and the curve point.
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let pubBytes = priv.publicKey.rawRepresentation
        let privBytes = priv.rawRepresentation

        await store.save(IntroKeyEntry(
            introPublicKey: pubBytes,
            introPrivateKey: privBytes,
            ownerIdentityID: ownerIdentityID,
            groupId: groupId,
            createdAt: now()
        ))

        return try IntroCapability(
            introPublicKey: pubBytes,
            groupId: groupId,
            groupName: groupName
        )
    }
}

enum IntroducerError: Error, Equatable {
    case invalidGroupID(actualSize: Int)
}
