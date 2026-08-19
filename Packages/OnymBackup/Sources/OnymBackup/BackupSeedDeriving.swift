import CryptoKit
import Foundation

/// How this package obtains seat-scoped key material without ever seeing
/// a seed.
///
/// `OnymBackup` deliberately does not depend on `OnymIdentity`. The
/// composition root conforms the identity repository to this protocol,
/// so the only thing that crosses the boundary is 32 derived bytes for
/// one `info` string — no seed, no entropy, no mnemonic, and no way to
/// ask for anything the caller did not name.
///
/// The `info` values are the ones `BackupKeys` builds; a conformer
/// applies HKDF-SHA256 with salt `app.onym.bip39` and returns 32 bytes.
/// Asynchronous because the holder of a seed is an actor: identity
/// material lives behind a serial executor, and a synchronous
/// requirement would force either a blocking hop or a nonisolated
/// accessor to secret state.
public protocol BackupSeedDeriving: Sendable {
    func deriveSeedScopedKey(info: String) async throws -> Data
}

extension BackupKeys {
    /// Derive the full key set for one operator through a seam that
    /// holds the seed.
    ///
    /// Throwing rather than optional: an identity with no recovery
    /// phrase cannot have a restorable archive, and the honest answer is
    /// to refuse enrolment and say so — not to seal something that will
    /// fail to open on the one device that ever tries.
    public static func material(
        deriving derivator: any BackupSeedDeriving,
        componentId: String,
        rotation: UInt32 = 0
    ) async throws -> BackupKeyMaterial {
        let archive = try await derivator.deriveSeedScopedKey(info: archiveInfo)
        let signing = try await derivator.deriveSeedScopedKey(
            info: signingInfo(componentId: componentId, rotation: rotation)
        )
        let agreement = try await derivator.deriveSeedScopedKey(
            info: agreementInfo(componentId: componentId, rotation: rotation)
        )
        // The 32-byte contract is documentation, and a conformer is
        // code we do not own. Force-unwrapping here would turn someone
        // else's bug into our crash, so it is checked.
        guard archive.count == 32, signing.count == 32, agreement.count == 32,
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: signing),
              let agreementKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreement)
        else {
            throw BackupError.localFailure(reason: .keyMaterialInvalid)
        }
        return BackupKeyMaterial(
            archiveRoot: SymmetricKey(data: archive),
            accessSigningKey: signingKey,
            accessAgreementKey: agreementKey,
            rotation: rotation
        )
    }
}
