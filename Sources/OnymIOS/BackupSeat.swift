import CryptoKit
import Foundation
import OnymBackup
import OnymBackupUI
import OnymBilling
import OnymChatsCore
import OnymFoundation
import OnymGroup
import OnymIdentity
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
@MainActor
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
        for reference in entitlementIssuers(componentId: componentId, consentStore: consentStore) {
            let prefix = "onym:key:"
            guard reference.hasPrefix(prefix) else { continue }
            let hex = String(reference.dropFirst(prefix.count))
            guard hex.count == 64 else { continue }
            var bytes = [UInt8]()
            var index = hex.startIndex
            var valid = true
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { valid = false; break }
                bytes.append(byte)
                index = next
            }
            guard valid, let key = try? Curve25519.Signing.PublicKey(
                rawRepresentation: Data(bytes))
            else {
                continue
            }
            return key
        }
        return nil
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
