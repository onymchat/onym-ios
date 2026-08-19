import CryptoKit
import Foundation
import OnymFoundation

/// Everything a holder needs at one operator, derived from the BIP39
/// seed and nothing else.
///
/// The seed is the root deliberately. Local at-rest encryption uses a
/// key pinned to this device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
/// which is right for a stolen phone and useless for a backup: a
/// snapshot sealed under a key that cannot leave the device is
/// unopenable on the replacement device, which is the only device that
/// will ever need it. Sealing therefore takes a *logical export* of
/// local state and re-seals it under these keys
/// (`UI-Backup-Object-HTTP.md` §5.1).
///
/// This type is the only thing that crosses into `OnymBackup` from
/// identity. The seed itself never does.
public struct BackupKeyMaterial: Sendable {
    /// Root of the archive key ladder. Each snapshot derives its own key
    /// from this plus a fresh public salt, so no two snapshots share key
    /// material and identical plaintext never produces identical bytes.
    public let archiveRoot: SymmetricKey
    /// Signs every request to this operator. Its public half, prefixed
    /// `onym:seat-key:`, is the holder's entire identity at the operator.
    public let accessSigningKey: Curve25519.Signing.PrivateKey
    /// The key a billing broker seals a `SeatEntitlement` to. The
    /// operator never sees it; a free operator's holder derives it and
    /// never uses it.
    public let accessAgreementKey: Curve25519.KeyAgreement.PrivateKey
    /// Which rotation these were derived at.
    public let rotation: UInt32

    public init(
        archiveRoot: SymmetricKey,
        accessSigningKey: Curve25519.Signing.PrivateKey,
        accessAgreementKey: Curve25519.KeyAgreement.PrivateKey,
        rotation: UInt32
    ) {
        self.archiveRoot = archiveRoot
        self.accessSigningKey = accessSigningKey
        self.accessAgreementKey = accessAgreementKey
        self.rotation = rotation
    }

    /// `onym:seat-key:<64 lowercase hex>` — the `X-Onym-Holder` value,
    /// and byte-for-byte what a `SeatEntitlement`'s `subject` must equal.
    public var holderReference: String {
        BackupKeys.holderReference(forSigningPublicKey: accessSigningKey.publicKey)
    }

    /// What the operator stores and shards on: a digest of the public
    /// key rather than the key itself, so nothing it persists is the
    /// credential.
    public var holderHandle: String {
        BackupKeys.holderHandle(forSigningPublicKey: accessSigningKey.publicKey)
    }
}

/// The derivations of `UI-Backup-Object-HTTP.md` §5.2.
///
/// All four are `HKDF-SHA256(seed, salt: "app.onym.bip39", info, 32)`,
/// matching the convention `Bip39.deriveNostrKey` and its siblings
/// already use — same root, same salt, different `info` per purpose.
public enum BackupKeys {
    /// Shared with `Bip39`'s own derivations: one namespace for
    /// everything grown from the seed.
    static let salt = Data("app.onym.bip39".utf8)

    static let archiveInfo = "backup-archive-v1"
    static let snapshotInfo = "backup-snapshot-v1"
    static let signingInfoPrefix = "backup-access-ed25519-v1"
    static let agreementInfoPrefix = "backup-access-x25519-v1"

    /// Domain separator for the handle. Distinct from every `info`
    /// string so a handle can never collide with a key.
    static let handleContext = Data("onym-backup-holder-v1".utf8)

    public static let holderReferencePrefix = "onym:seat-key:"

    /// Derive the full set directly from a seed.
    ///
    /// Internal on purpose. Production code goes through
    /// `material(deriving:componentId:rotation:)`, so a seed is never
    /// passed across a package boundary; this overload exists for
    /// fixtures that start from a known mnemonic and need to assert what
    /// the derivation produces.
    ///
    /// `componentId` is inside the access-key `info`, which is what
    /// makes these keys per-operator: two operators see two unrelated
    /// public keys, and neither can be linked to the identity's Nostr,
    /// BLS, Stellar, or inbox keys. That is the anti-correlation rule of
    /// `WHITEPAPER.md` §17.5, enforced by derivation rather than by
    /// policy.
    static func material(
        seed: Data,
        componentId: String,
        rotation: UInt32 = 0
    ) -> BackupKeyMaterial {
        // Both initializers can only fail on a wrong byte count, and
        // HKDF always yields exactly the 32 bytes Curve25519 wants — so
        // a failure here would mean CryptoKit changed under us, not that
        // a caller passed something bad. Force-unwrapped rather than
        // pushed into every caller's error path.
        let signing = derive(seed: seed, info: signingInfo(componentId: componentId, rotation: rotation))
        let agreement = derive(seed: seed, info: agreementInfo(componentId: componentId, rotation: rotation))
        return BackupKeyMaterial(
            archiveRoot: archiveRootKey(seed: seed),
            // swiftlint:disable:next force_try
            accessSigningKey: try! Curve25519.Signing.PrivateKey(rawRepresentation: signing),
            // swiftlint:disable:next force_try
            accessAgreementKey: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreement),
            rotation: rotation
        )
    }

    public static func archiveRootKey(seed: Data) -> SymmetricKey {
        SymmetricKey(data: derive(seed: seed, info: archiveInfo))
    }

    /// One snapshot's key, from the archive root and that snapshot's
    /// fresh public salt.
    ///
    /// The salt is the input keying material's *salt*, not part of the
    /// info string: HKDF's extract step is what a per-snapshot salt is
    /// for, and it gives every snapshot an independent key even though
    /// the root never changes.
    public static func snapshotKey(archiveRoot: SymmetricKey, snapshotSalt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: archiveRoot,
            salt: snapshotSalt,
            info: Data(snapshotInfo.utf8),
            outputByteCount: 32
        )
    }

    /// `<prefix>|<componentId>|r<rotation>` — unambiguous without
    /// escaping, because a `componentId` is a colon-delimited URN with
    /// no `|` in it.
    static func signingInfo(componentId: String, rotation: UInt32) -> String {
        "\(signingInfoPrefix)|\(componentId)|r\(rotation)"
    }

    static func agreementInfo(componentId: String, rotation: UInt32) -> String {
        "\(agreementInfoPrefix)|\(componentId)|r\(rotation)"
    }

    public static func holderReference(forSigningPublicKey key: Curve25519.Signing.PublicKey) -> String {
        holderReferencePrefix + key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    public static func holderHandle(forSigningPublicKey key: Curve25519.Signing.PublicKey) -> String {
        var input = handleContext
        input.append(key.rawRepresentation)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func derive(seed: Data, info: String) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: seed),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }
}
