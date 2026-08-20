import CryptoKit
import Foundation
import OnymBackup
import OnymBackupUI
import OnymBilling
import OnymChatsCore
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymModeration
import OnymPersistence
import OnymTransportBlossom

/// Assembles the device-backup seat from what the person has actually
/// chosen.
///
/// Nothing here decides anything: the operator comes from a pinned
/// consent record, its terms come from that operator's signed manifest,
/// and the keys come from the identity vault. If no backup operator has
/// been consented to, this resolves to `nil` and Settings shows no
/// backup section — which is correct, not a degraded state.
/// Not `@MainActor`.
///
/// It was, and the annotation was not honoured: `entitlementIssuers` is
/// called synchronously from nonisolated `@Sendable` closures that run
/// inside the purchase-flow actor and the entitlement provider, off the
/// main actor. That is a warning in Swift 5 and a hard error in Swift 6,
/// and in the meantime it meant main-actor-annotated code running
/// elsewhere. Everything here is a pure read of a `Sendable` store, so
/// dropping the isolation is the honest fix rather than adding hops that
/// would only make the annotation true.
enum BackupSeat {
    /// The seat value a backup operator declares.
    static let seat = "storage.backup"

    /// The consented backup operator, if there is one.
    ///
    /// Reads the *active* pinned record. A person who switched
    /// operators has a history of records; only the current one may
    /// receive a snapshot.
    static func consentedManifest(
        consentStore: any PinnedConsentStore
    ) -> BackupOperatorManifest? {
        guard let records = try? consentStore.load() else { return nil }
        for record in records.reversed() where record.isActive {
            guard
                let manifest = record.consentedManifest(),
                manifest.seat == seat,
                let backup = try? BackupOperatorManifest(manifest: manifest)
            else {
                continue
            }
            return backup
        }
        return nil
    }

    /// Issuer keys an operator declares. Pinned from the signed
    /// manifest, never from an entitlement — a credential must not be
    /// able to nominate its own authority.
    static func entitlementIssuers(
        componentId: String,
        consentStore: any PinnedConsentStore
    ) -> [String] {
        guard
            let record = try? consentStore.activeRecord(componentId: componentId),
            let manifest = record.consentedManifest(),
            let backup = try? BackupOperatorManifest(manifest: manifest)
        else {
            return []
        }
        return backup.entitlementIssuers
    }

    /// The first declared issuer, as a key.
    ///
    /// Returns `nil` when nothing has been consented to for that
    /// component, or when the operator declared no issuers — a free
    /// operator, which never issues a payment refusal and therefore
    /// never needs one.
    static func entitlementIssuerKey(
        componentId: String,
        consentStore: any PinnedConsentStore
    ) -> Curve25519.Signing.PublicKey? {
        // `AuthorityKey` is the one `onym:key:` parser in this codebase.
        // A second hand-rolled one is a second place for the hex rules
        // to drift.
        for reference in entitlementIssuers(componentId: componentId, consentStore: consentStore) {
            if let key = try? AuthorityKey.publicKey(fromReference: reference) {
                return key
            }
        }
        return nil
    }

    /// Where a restore puts attachment ciphertext it recovered.
    ///
    /// Read by `RestoredBlobClient`, which the media loaders go through
    /// — that wrapping is what makes a restored attachment visible
    /// rather than merely present on disk.
    static func restoredBlobDirectory() throws -> URL {
        try workingDirectory().appending(path: "blobs")
    }

    /// Where sealed snapshots and local backup state live.
    static func workingDirectory() throws -> URL {
        let base = try PersistentStoreOpener.storeDirectory()
        let url = base.appending(path: "Backup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return url
    }
}

/// Seat-scoped keys for the billing layer, derived from the identity
/// vault.
///
/// `OnymBilling` cannot derive these itself — they belong to whichever
/// seat is being bought — and `OnymBackup` must not depend on identity.
/// The composition root is the only place that knows all three, which is
/// why the conformance lives here.
struct IdentitySeatAccessKeys: SeatAccessKeyProviding {
    let identities: IdentityRepository

    func seatSubject(componentId: String) async throws -> String {
        try await material(componentId: componentId).holderReference
    }

    func seatAgreementKey(
        componentId: String
    ) async throws -> Curve25519.KeyAgreement.PrivateKey {
        try await material(componentId: componentId).accessAgreementKey
    }

    private func material(componentId: String) async throws -> BackupKeyMaterial {
        try await BackupKeys.material(deriving: identities, componentId: componentId)
    }
}
