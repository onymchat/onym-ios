import CryptoKit
import Foundation

/// Stable opaque handle for one of the user's identities.
///
/// Backed by a UUID, but type-distinct so the compiler stops us from
/// accidentally passing a `UUID` from another domain (e.g. an
/// `OnymInvitee.id`) anywhere an identity is expected.
///
/// Persisted via the keychain `kSecAttrService` suffix
/// (`app.onym.ios.identity.<uuidString>`) and inside `ChatGroup` rows
/// (post-PR-3) so any group can be traced back to the identity that
/// owns it without a separate join table.
public struct IdentityID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    /// Random ID. Only correct for an identity that has no entropy behind
    /// it — which, in the app, is none of them: every production identity
    /// is minted from BIP39 entropy and must use
    /// `init(derivedFromEntropy:)` instead, or the identity stops being
    /// recoverable (see that initialiser). The default argument is kept
    /// because tests mint hundreds of throwaway owner IDs that never touch
    /// a mnemonic, and forcing them through a fake entropy blob would buy
    /// nothing. If a second production call site ever wants this, that is
    /// the moment to delete the default and make callers say `IdentityID(UUID())`
    /// out loud.
    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// Derive the ID from the BIP39 entropy that backs the identity, so
    /// importing a recovery phrase reproduces the *same* ID it had before.
    ///
    /// This is load-bearing for backup restore. Groups and messages are
    /// scoped by owner (`MessageStore.list(groupID:ownerIDString:)`,
    /// `ChatGroup.ownerIdentityID`), so an archive written by identity A
    /// is invisible to identity B. When the ID was a fresh random UUID on
    /// every creation — including on import — restoring after entering a
    /// recovery phrase produced a device holding every row and showing
    /// none of them: the restore summary counted the chats, the chat list
    /// stayed empty. The entropy is the only thing an import actually
    /// carries across devices, so the ID has to come from it.
    ///
    /// **Domain separation.** The entropy is also the root of the Nostr
    /// and BLS secret keys, and this value is not secret: it lands in a
    /// keychain service name and in plaintext SwiftData rows. HKDF with a
    /// distinct `info` label is what keeps those worlds apart — the ID is
    /// computationally unrelated to any key derived from the same seed, so
    /// possessing it reveals nothing about them and it can never be
    /// mistaken for, or fed in as, key material. The label is
    /// `identity-id-v1`; the `v1` is there so a future change of scheme
    /// can be a new label rather than a silent reinterpretation of the
    /// same bytes. The salt matches `Bip39.deriveNostrKey` /
    /// `deriveBlsKey` (`app.onym.bip39`) so the whole seed hierarchy has
    /// one root salt and the labels alone do the separating — that is
    /// exactly the job HKDF's `info` parameter exists to do.
    ///
    /// Note this takes the raw entropy, not the PBKDF2 seed the secret
    /// keys are derived from. Both are deterministic functions of the
    /// mnemonic so either would reproduce, but the entropy is one step
    /// further from the key material and far cheaper for another platform
    /// to match — Android has to compute the identical ID from the
    /// identical phrase or a cross-platform restore shows an empty app
    /// for the same reason this bug did.
    ///
    /// **Version bits.** The output is stamped as a v4 (random) UUID even
    /// though it is derived. `IdentityID` round-trips through
    /// `UUID(uuidString:)` for keychain service names and persisted
    /// `ChatGroup` rows, so the value must be a well-formed UUID or it
    /// fails to parse somewhere far away from here. RFC 9562's v8
    /// ("custom") is the more literally honest version nibble, and it was
    /// rejected: it would make every derived ID visually distinguishable
    /// from a legacy random one, printing "this identity is seed-derived"
    /// into every keychain service name and every stored row. Nothing
    /// downstream needs to know which way an ID was minted, and a value
    /// that quietly announces something about its owner is the shape of
    /// thing this codebase is meant not to emit.
    public init(derivedFromEntropy entropy: Data) {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: entropy),
            salt: Data("app.onym.bip39".utf8),
            info: Data("identity-id-v1".utf8),
            outputByteCount: 16
        )
        var bytes = derived.withUnsafeBytes { [UInt8]($0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40  // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        self.rawValue = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// `nil` if `string` isn't a parseable UUID. Used when reconstructing
    /// the ID from a keychain service suffix or a persisted ChatGroup row.
    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    public var description: String { rawValue.uuidString }

    // Codable round-trips as the UUID's string form so persisted JSON +
    // keychain service names stay readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        guard let uuid = UUID(uuidString: str) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "IdentityID: \(str.prefix(40)) is not a UUID"
            )
        }
        self.rawValue = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }
}
